# -*- encoding : utf-8 -*-
# require 'digest'

class MediaFile < ActiveRecord::Base
  # before_create :set_filename
  before_create :assign_access_hash
  before_create :validate_file
  after_create  :store_file
  after_destroy :delete_file

  validates_presence_of :uploaded_data

  attr_accessor :uploaded_data

  serialize     :meta_data, Hash

  has_many      :media_entries # TODO validation: at least one media_entry (even empty) 
  has_many      :previews, :dependent => :destroy # TODO - the eventual resting place of all preview files derived from the original (e.g. thumbnails)

  scope :original, where(:parent_id => nil)

#########################################################

  def get_preview(size = nil)
    unless size.blank?
      #tmp# p = previews.where(:thumbnail => size.to_s).first
      p = previews.detect {|x| x.thumbnail == size.to_s}
      p ||= begin
        make_thumbnails([size])
        #tmp# previews.where(:thumbnail => size.to_s).first
        previews.detect {|x| x.thumbnail == size.to_s}
      end
      # OPTIMIZE p could still be nil !!
      return p
    else
      # get the original
      return file_storage_location
    end
  end

  def import
    case content_type
      when /image/ then
        import_image_metadata(file_storage_location) if previews.empty? # TODO why?
        make_thumbnails
      when /video/ then
        import_audio_video_metadata(file_storage_location)
        make_thumbnails
      when /audio/ then
        import_audio_metadata(file_storage_location)
        make_thumbnails
      when /application/ then
        import_document_metadata(file_storage_location)
      else
        # TODO implement other content_types
    end
    update_attributes(:meta_data => meta_data)
  end


# Write the file out to storage
  def store_file
    FileUtils.cp uploaded_data[:tempfile].path, file_storage_location

    # TODO in background?
    import if meta_data.blank?
  end

# We need to ensure that the media file is not still being used by another media_entry.
  def delete_file
    File.delete(file_storage_location)
  end


# The final resting place of the media file. consider it permanent storage.
# basing the shard on (some non-zero) part of the guid gives us a trivial 'storage balancer' which completely ignores
# any size attributes of the file, and distributes amongst directories pseudorandomly (which in practice averages out in the long-term).
# 
  def file_storage_location
    File.join(FILE_STORAGE_DIR, shard, guid)
  end

# remember, thumbnails *could* be on a faster storage medium than original files.
  def thumbnail_storage_location
    File.join(THUMBNAIL_STORAGE_DIR, shard, guid)
  end

  # set some attributes, for use when storing the file.
  # NB Depending on if we are being called from a rake task or the webserver, we either get a tempfile or an array.
  def set_filename
    self.guid = get_guid 
    # Same issue as above, we get a hash or an object, depending on appserver or rake task call.
    if uploaded_data.kind_of? Hash
      self.filename = CGI::escape(uploaded_data[:filename])
      self.size = File.size(uploaded_data[:tempfile].path)
      self.content_type = uploaded_data[:type]
    else
      self.filename = CGI::escape(uploaded_data.original_filename)
      self.size = uploaded_data.size
      self.content_type = uploaded_data.content_type
    end
  end

  # the cornerstone of identity..
  # in an ideal world, this is farmed off to something that can crunch through large files _fast_
  def get_guid
    # This was the old GUID code in use up to June, 2011. Please leave to code here
    # so we know why older files have different GUIDs. The new GUID code doesn't take
    # the file hash into account at all, which is much faster at the expensve of a very
    # low probability of file duplication.
    # We can solve the file duplication problem elsewhere, e.g. by nightly hashing over all files
    # that have identical size and assigning the media entries to the same file if there is a
    # match on the hash. This would be a lot less expensive than doing it during upload.
    #     # TODO in background?
    #     # Hash or object, we should be seeing a pattern here by now.
    #     if uploaded_data.kind_of? Hash
    #       g = Digest::SHA256.hexdigest(uploaded_data[:tempfile].read)
    #       uploaded_data[:tempfile].rewind
    #     else
    #       g = Digest::SHA256.hexdigest(uploaded_data.read)
    #       uploaded_data.rewind
    #     end
    #     g

    return UUIDTools::UUID.random_create.hexdigest
    
  end

  def shard
    # TODO variable length of sharding?
    self.guid[0..0]
  end

  def make_thumbnails(sizes = nil)
    # this should be a background job
    if content_type.include?('image')
      thumbnail_jpegs_for(file_storage_location, sizes)
    elsif content_type.include?('video')
      submit_encoding_job
    elsif content_type.include?('audio')
      #add_audio_thumbnails   # This might be a future method that constructs some meaningful thumbnail for an audio file?
      submit_encoding_job
    end
  end
  
  def retrieve_encoded_files
    require Rails.root + 'lib/encode_job'
    paths = []
    thumbnail_paths = []

    unless self.job_id.blank?
      job = EncodeJob.new(self.job_id)
      if job.finished?
        # Get the encoded files via FTP
        job.encoded_file_urls.each do |f|
          filename = File.basename(f)
          prefix = "#{thumbnail_storage_location}_encoded"
          path = "#{prefix}_#{filename}"
          `wget "#{f}" -O "#{path}"`
          if $? == 0
            paths << path
          end
        end
        
        job.thumbnail_file_urls.each do |f|
          filename = File.basename(f).split("?")[0] # Take the first part of the name before the query string only
                                                    # example basename otherwise:
                                                    # frame_0000.png?AWSAccessKeyId=AKIAI456JQ76GBU7FECA&Signature=VpkFCcIwn77IucCkaDG7pERJieM%3D&Expires=1325862058
          prefix = "#{thumbnail_storage_location}_encoded"
          path = "#{prefix}_#{filename}"
          `wget "#{f}" -O "#{path}"`
          if $? == 0
            thumbnail_paths << path
          end
        end
        
        # If any of the encoding jobs resulted in a PNG screenshot of the film, use
        # that as a thumbnail
        pngs = thumbnail_paths.select{|path| path.match(/\.png$/)}
        thumbnail_jpegs_for(pngs[0]) unless pngs.empty?
        
      end
    end
        
    return paths
  end

  # Video thumbnails only come in one size (large) because re-encoding these costs money and they only make sense
  # in the media_entries/show view anyhow (not in smaller versions).
  def assign_video_thumbnails_to_preview
    content_type = "video/webm"
    if previews.where(:content_type => content_type).empty?
      paths = retrieve_encoded_files
      unless paths.empty?
        paths.each do |path|
          if File.extname(path) == ".webm"
            # Must have Exiftool with Image::ExifTool::Matroska to support WebM!
            w, h = exiftool_obj(path, ["Composite:ImageSize"])[0][0][1].split("x")
            if previews.create(:content_type => content_type, :filename => File.basename(path), :width => w.to_i, :height => h.to_i, :thumbnail => 'large')
              # Link the file to a symlink inside of public/ so that Apache serves the preview file, otherwise
              # it would become far too hard to support partial content (status 206) and ranges (for seeking in media files)
              File.symlink(path, Rails.root + "public/previews/#{File.basename(path)}")
              return true
            else
              return false
            end
          end
        end
      end
    end
  end

  def assign_audio_previews
    content_type = "audio/ogg"
    if previews.where(:content_type => content_type).empty?
      paths = retrieve_encoded_files
      unless paths.empty?
        paths.each do |path|
          if File.extname(path) == ".ogg"
            if previews.create(:content_type => content_type, :filename => File.basename(path), :width => 0, :height => 0, :thumbnail => 'large')
              return true
            else
              return false
            end
          end
        end
      end
    end
  end
  
  def thumbnail_jpegs_for(file, sizes = nil)
    return unless File.exist?(file)
    THUMBNAILS.each do |thumb_size,value|
      next if sizes and !sizes.include?(thumb_size)
      tmparr = thumbnail_storage_location
      tmparr += "_#{thumb_size.to_s}"
      outfile = [tmparr, 'jpg'].join('.')
      `convert -verbose "#{file}" -auto-orient -thumbnail "#{value}" -flatten -unsharp 0x.5 "#{outfile}"`
      if File.exists?(outfile)
        x,y = `identify -format "%wx%h" "#{outfile}"`.split('x')
        if x and y
          previews.create(:content_type => 'image/jpeg', :filename => outfile.split('/').last, :height => y, :width => x, :thumbnail => thumb_size.to_s )
        end
      else
        # if convert failed, we need to take or delegate off some rescue action, ideally.
        # but for the moment, lets just imply no-thumbnail need be made for this size
      end
    end
  end

  def validate_file
    #TODO - check for zip files and process accordingly
      unless importable_zipfile?
        set_filename
      else
        explode_and_import(uploaded_data)
        # do the explode and import in the background
      end
  end

  def thumb_base64(size = :small)
    # TODO give access to the original one?
    # available_sizes = THUMBNAILS.keys #old# ['small', 'medium']
    # size = 'small' unless available_sizes.include?(size)

    preview = case content_type
                when /video/ then
                  # Get the video's covershot that we've extracted/thumbnailed on import
                  get_preview(size) || "Video"
                when /audio/ then
                  "Audio"
                when /image/ then
                  get_preview(size) || "Image"
                else 
                  "Doc"
              end

    # OPTIMIZE
    unless preview.is_a? String
      file = File.join(THUMBNAIL_STORAGE_DIR, shard, preview.filename)
      if File.exist?(file)
       output = File.read(file)
       return "data:#{preview.content_type};base64,#{Base64.encode64(output)}"
      else
        preview = "Image" # OPTIMIZE
      end
    end

    # nothing found, we show then a placeholder icon
    case Rails.env
      when "development"
        w, h = THUMBNAILS[size].split('x').map(&:to_i)
        categories = %w(abstract food people technics animals nightlife nature transport city fashion sports)
        cat = categories[id % categories.size]
        n = (id % 10) + 1
        return "http://lorempixum.com/#{w}/#{h}/#{cat}/#{n}"
      else
        size = (size == :large ? :medium : :small)
        output = File.read("#{Rails.root}/app/assets/images/#{preview}_#{size}.png")
        return "data:#{content_type};base64,#{Base64.encode64(output)}"
    end
  end
    
######################################################################

  def importable_zipfile?
    if uploaded_data.kind_of? Hash
      ret = uploaded_data[:filename].include?('__IMPORT__') and uploaded_data[:filename].include?('.zip')
    else
      ret = uploaded_data.original_filename.include?('__IMPORT__') and uploaded_data.original_filename.include?('.zip')
    end
    ret
  end


# IMAGES 
  def import_image_metadata(full_path_file)
    self.meta_data ||= {}
    group_tags = ['File:', 'Composite:', 'IFD', 'ICC-','ICC_Profile','XMP-exif', 'XMP-xmpMM', 'XMP-aux', 'XMP-tiff', 'Photoshop:', 'ExifIFD:', 'JFIF', 'IFF:', 'GPS:', 'PNG:' ] #'System:' leaks system info
    ignore_fields = ['UserComment','ImageDescription', 'ProfileCopyright', 'System:']
    exif_hash = {}

    blob = exiftool_obj(full_path_file, group_tags)
    blob.each do |tag_array_entry|
      tag_array_entry.each do |entry|
        exif_hash[entry[0]]=entry[1] unless ignore_fields.any? {|w| entry[0].include? w }
      end
      meta_data.merge!(exif_hash)
    end
    # FIXME - We are inserting image-specific data into a model that is generic in intent, for the convenience of it all.
    # Apparently IFD0 is not the best fit (some files don't contain it), perhaps we should use the Composite:ImageSize tag, till we get rid of these columns..
    img_x, img_y = exif_hash["Composite:ImageSize"].split("x")
    update_attributes(:width => img_x, :height => img_y)
  end

#####################################################################################################################

  def import_audio_video_metadata(full_path_file)
    # TODO: merge with import_image_metadata, make fields configurable in :options hash
    self.meta_data ||= {}

    # The Tracks: entries describe video, audio or subtitle tracks present in the container. We extract 10
    # because we think no one would be mad enough to have more.
    tracks = []
    [1..10].each do |n|
      tracks << "Track#{n}:"
    end
    
    group_tags = ['File:', 'Composite:', 'IFD', 'ICC-','ICC_Profile','XMP-exif', 'XMP-xmpMM', 'XMP-aux', 'XMP-tiff', 'Photoshop:', 'ExifIFD:', 'JFIF', 'IFF:', 'GPS:', 'PNG:', 'QuickTime:'] + tracks #'System:' leaks system info
    ignore_fields = ['UserComment','ImageDescription', 'ProfileCopyright', 'System:']
    exif_hash = {}

    blob = exiftool_obj(full_path_file, group_tags)
    blob.each do |tag_array_entry|
      tag_array_entry.each do |entry|
        exif_hash[entry[0]]=entry[1] unless ignore_fields.any? {|w| entry[0].include? w }
      end
      meta_data.merge!(exif_hash)
    end

    # Exiftool couldn't get the dimensions. Let's try with ffmpeg
    if exif_hash["Composite:ImageSize"].nil?
      img_x, img_y = get_sizes_from_ffmpeg(full_path_file)
    else
      img_x, img_y = exif_hash["Composite:ImageSize"].split("x")
    end
    update_attributes(:width => img_x, :height => img_y)
  end

  def get_sizes_from_ffmpeg(path)
    out = `ffmpeg -i #{path} 2>&1`
    out.split("\n").each do |line|
      if line =~ /.*Stream.*Video.*/
        x, y = line.scan(/\d+x\d+/).first.split("x")
        return [x, y]
      end
    end
  end
  
  def import_audio_metadata(full_path_file)

    # TODO refactor to use ffmpeg, some id3 tag extractor, etc.
  end
  
# This kind of thing REALLY needs to happen of elsewhere asynchronously, otherwise we move inexorably towards the day the site gets DOS'd. 
# ie when a user uploads a malevolent zip that unpacks to some ridiculous storage-busting size..
# TODO - explode and import the contents of a zip file
# this may be a rag-tag collection of any old rubbish, so we need to try and impose a few minimal rules on the proceedings.
# - contains some kind of media file (as per madek media types list)
# - optionally contains an xml metadata file, conforming to the Dublin Core XML schema, or other agreed schemas
  def explode_and_import(full_path_file)

    racer_x = rand(Time.now.to_i).to_s
    Dir.mkdir("#{Rails.root}/tmp/unzipfiles/#{racer_x}")
    # logger.info "inspect: #{full_path_file[:tempfile].inspect}"
    # logger.info "full_path_file[:tempfile] stat=#{full_path_file[:tempfile].stat.inspect}"
    # logger.info "full_path_file[:tempfile] path=#{full_path_file[:tempfile].path.inspect}"
    z = Zip::ZipFile.open(full_path_file[:tempfile].path)
    mf = []
    # logger.info { "*****************************************************************" }
    # logger.info { "ZIPFLE HAS #{z.entries.size} ENTRIES" }
    destination = "#{Rails.root}/tmp/unzipfiles/#{racer_x}/" # TODO configurable
    z.each do |ent|
      next if ent.name =~ /__MACOSX/ or ent.name =~ /\.DS_Store/ or !ent.file?
      # logger.info "ZIPFLE Entry #{ent}"
      f_path=File.join(destination, ent.name)
      # logger.info "f_path=#{f_path}"
      FileUtils.rm_rf f_path if File.exist?(f_path)
      # logger.info "remove pth"
      FileUtils.mkdir_p(File.dirname(f_path))
      # logger.info "made directory"
      z.extract(ent, f_path)
      # logger.info "just extracted #{ent} to #{f_path}"
      mimetype = `#{FILE_UTIL_PATH} "#{Rails.root}/tmp/unzipfiles/#{racer_x}/#{ent}"`.gsub(/\n/,"")
      # logger.info "mimetype=#{mimetype}"

      #TODO something intelligent and asynchronous here, to allow us to go through the files in the zip and insert them, optionally adding any yaml metadata we find that relate to media.
      # mf << MediaFile.create(:uploaded_data => ActionController::TestUploadedFile.new("#{Rails.root}/tmp/unzipfiles/#{racer_x}/#{ent}", mimetype))
    end
    resout = `rake madek:importer:import[#{full_path_file["current_user"]}, "#{Rails.root}/tmp/unzipfiles/#{racer_x}/"]`
    res = $?
  end


  def import_document_metadata(full_path_file)
    #TODO - specifically for other non-zipped documents (e.g. source code, application binary, etc)
  end

  
  def submit_encoding_job(force = false)
    if force == true or job_id.blank?
      # submit http://this_host/download?media_file_id=foo&access_hash=bar
      require Rails.root + 'lib/encode_job'
      job = EncodeJob.new
      if content_type.include?('video')
        job.job_type = "video"
      elsif content_type.include?('audio')
        job.job_type = "audio"
      else
        raise ArgumentError, "Can only handle encoding jobs for content types video/* and audio/*, not #{content_type}"
      end
      # Note: We cannot use media_entry_url(self.id) here because ENCODING_BASE_URL may include
      # a username/password (e.g. http://test:foo@www.blah.com) for Zencoder or other encoding
      # services to reach the file by.
      job.start_by_url("#{ENCODING_BASE_URL}/media_files/#{self.id}?access_hash=#{self.access_hash}")
      # Save Zencoder job ID so we can use it in subsequent requests
      update_attributes(:job_id => job.details['id'])
      return job
    else
      logger.error("Won't encode -- this file already has a job_id, so it's probably already been encoded. Use submit_encoding_job(force = true) to override.")
      return false
    end
  end
  
  # TODO: Refactor into something like MediaFile#encode_job ?
  def encode_job_finished?
    if self.job_id.blank?
      return false
    else
      require Rails.root + 'lib/encode_job'
      job = EncodeJob.new(self.job_id)
      return job.finished?
    end
  end
  
  def encode_job_progress_percentage
    if self.job_id.blank?
      return 0
    else
      require Rails.root + 'lib/encode_job'
      job = EncodeJob.new(self.job_id)
      return job.progress['progress'].to_f
    end
  end
  
  
  def assign_access_hash
    self.access_hash = UUIDTools::UUID.random_create.to_s
  end

  def reset_access_hash
    assign_access_hash
    return save
  end

  # OPTIMIZE
  def meta_data_without_binary
    r = meta_data.reject{|k,v| ["!binary |", "Binary data"].any?{|x| v.to_yaml.include?(x)}}
    r.map {|x| x.map{|y| y.to_s.dup.force_encoding('utf-8') } }
  end
  
  private


 # parses the passed in file reference for the requested tag groups (using exiftool)
 # returns an array of arrays of meta-data for the group tags requested
  def exiftool_obj(full_path_file, tags = nil)
    result_set = []
    parse_hash = JSON.parse(`#{EXIFTOOL_PATH} -s "#{full_path_file}" -a -u -G1 -D -j`).first
    parse_hash.delete_if {|k,v| v.is_a?(String) and not v.valid_encoding? }
    tags.each do |tag_group|
      result_set << parse_hash.select {|k,v| k.include?(tag_group)}.sort
    end
    result_set
  end

  
end
