When /^(?:|I )open the "(.+)" set$/ do |title|
  id = nil
  MediaSet.all.each do |set|
    if set.title == title
      id = set.id
      break
    end
  end
  visit media_set_path(id)
end

When /^(?:|I )open the "(.+)" entry/ do |title|
  id = nil
  MediaEntry.all.each do |entry|
    if entry.title == title
      id = entry.id
      break
    end
  end
  visit media_entry_path(id)
end

When /^(?:|I )open the selection widget for this (.+)$/ do |type|
  case type
    when "set"
      find("#set_actions .has-set-widget").click
    when "entry"
      find("#detail-action-bar .has-set-widget").click
    when "batchedit"
      find(".task_bar .has-set-widget").click
    when "page"
      find(".has-set-widget").click
  end
  wait_for_css_element(".widget .list")
end

When /^(?:|I )select "(.+)" as parent set$/ do |label|
  label.gsub!(/\s/, "_")
  find("input##{label}:not(selected)").click
end

When /^(?:|I )deselect "(.+)" as parent set$/ do |label|
  label.gsub!(/\s/, "_")
  raise "#{label} is not selected so you can not deselect it" unless find("input##{label}").checked?
  find("input##{label}").click
end

When /^(?:|I )submit the selection widget$/ do
  find(".widget .submit").click
  sleep(15)
end

When /^(?:|I )create a new set named "(.+)"$/ do |name|
  find(".widget .create_new a").click
  wait_for_css_element("#create_name")
  fill_in("create_name", :with => name)
  find(".widget .create_new .button").click
  wait_for_css_element(".create_new a")
end

When /^(?:|I )create a new set$/ do
  find(".widget .create_new a").click
  find(".widget .create_new div.button").click
  wait_for_css_element(".create_new a")
end

When /^(?:|I )should see the "(.+)" set inside the widget$/ do |name|
  find(".widget").should have_content(name)
end

When /^(?:|I )should not see the "(.+)" set inside the widget$/ do |name|
  find(".widget").should have_no_content(name)
end

When /^(?:|I )search for "(.+)"$/ do |search|
  fill_in("widget_search", :with => search)
end

