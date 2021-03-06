# -*- encoding : utf-8 -*-
class Preview < ActiveRecord::Base

  after_destroy { File.delete(full_path) }

  belongs_to :media_file

  def full_path
    File.join(THUMBNAIL_STORAGE_DIR, filename[0,1], filename)    
  end

  def size
    File.size(full_path)
  end

end
