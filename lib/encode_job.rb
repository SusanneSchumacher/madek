#!/usr/bin/ruby

require 'rubygems'

require 'yaml'

require 'zencoder'  # This doesn't work? What the?
#require '/usr/lib/ruby/gems/1.8/gems/zencoder-2.3.1/lib/zencoder' # This works. What the?


# documentation: https://github.com/zencoder/zencoder-rb

# use the API builder to build requests: https://app.zencoder.com/api_builder

class EncodeJob

  attr_accessor :job_id # Unique job ID that the encoder system (e.g. Zencoder) should assign to us
  attr_accessor :base_url # Output location where finished encodes should be stored
                          # (FTP or SFTP URL including username/password)
  attr_accessor :size    # The target sizes for the encode job. Ignored for audio-only jobs.
  attr_accessor :video_codec  # Usually 'vp8'
  attr_accessor :audio_codec # Usually 'vorbis'
  attr_accessor :job_type # video or audio

  
  def initialize(job_id = nil)
    @job_id = job_id unless job_id.nil?
    config = YAML::load(File.open(Rails.root + "config/zencoder.yml"))
    api_key = config['zencoder']['api_key']
    @base_url = config['zencoder']['ftp_base_url']
    @size ||= { :width => 640 }
    @video_codec ||= "vp8"
    @audio_codec ||= "vorbis"
    @job_type ||= "video"
    Zencoder.api_key = api_key
  end


  # TODO: Add notification callback URLs
  # :notifications => ["http://medienarchiv.zhdk.ch/encode_jobs/notification"]
  
  def start_by_url(url)

    options = {:base_url => @base_url, :quality => 4, :speed => 2}

    if @type == "video"
      options.merge!(:video_codec => @video_codec).merge!(@size)
    elsif @type == "audio"
      options.merge!(:audio_codec => @audio_codec)
    end

    puts "options were: #{options.inspect}"
    
    outputs = [options]  # You can chain more outputs onto this array
    
    settings = {:input => url,
                :outputs => outputs}

    response = Zencoder::Job.create(settings)
    if response.success?
      @job_id = response.body['id']
      return true
    else
      @job_id = nil
      return false
    end
  end
  
  def details
    Zencoder::Job.details(@job_id).body['job']
  end

  def state
    details['state']
  end

  def finished?
    state == "finished"
  end

  # Not THAT useful, we should instead extract all info we need manually from +details+
  def encoded_file_urls
    paths = []
    details['output_media_files'].each do |file|
      paths << file['url']
    end
    return paths
  end
  
end


# Example use follows
# job = EncodeJob.new
# 
# response = job.start_by_url("http://medienarchiv.zhdk.ch/encode/grumpy_cat.mp4")
# 
# puts job.details.inspect


#Zencoder.api_key = 'abcd1234'
#response = Zencoder::Job.list
