class RefactorMetaDate < ActiveRecord::Migration
  def self.up

    key = MetaKey.where(:label => "portrayed object dates").first
    if key
      key.update_attributes(:object_type => "Meta::Date")
      key.meta_data.each do |md|
        md.update_attributes(:value => md.value)
      end
    end

  end

  def self.down
  end
end
