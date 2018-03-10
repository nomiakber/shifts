require 'casclient'
require 'casclient/frameworks/rails/filter'


module FeatureHelper
  def sign_in(netid)
    RubyCAS::Filter.fake(netid)
  end

  # Equivalent to going through first-run setup
  def app_setup
    @app_config = create(:app_config)
    @department = create(:department)
    @superuser = create(:superuser)
    # Default created with department
    @category = @department.categories.where(name: "Shifts").first
    @calendar = @department.calendars.default
  end

  # Does app_setup, creates a Location Group with a location, an ordinary role and an admin_role with default permissions, an ordinary user and an admin.
  def full_setup
    app_setup
    @loc_group = create(:loc_group)
    @location = create(:location, loc_group: @loc_group, category: @category)
    @ord_role = create(:role)
    @admin_role = create(:admin_role)
    @admin = create(:admin)
    @user = create(:user)
  end

  # Capybara expectation helpers, does not modify browser state
  def expect_flash_notice(message, type="notice")
    expect(find("#flash_#{type}.alert")).to have_content(message)
  end

  # Capybara brower helpers, modifies browser state
  def fill_in_date(prefix, target_datetime)
    select target_datetime.year.to_s, :from => "#{prefix}_1i" 
    select Date::MONTHNAMES[target_datetime.month], :from => "#{prefix}_2i"
    select target_datetime.day.to_s, :from => "#{prefix}_3i"
  end

  def fill_in_time(prefix, target_time)
    begin
      select target_time.strftime("%I %p"), from: "#{prefix}_4i"
      inc = @department.department_config.time_increment
      select ("%.2d" % target_time.min/inc*inc), from: "#{prefix}_5i"
    rescue
      select target_time.strftime("%H"), from: "#{prefix}_4i"
      select target_time.strftime("%M"), from: "#{prefix}_5i"
    end
  end
end

