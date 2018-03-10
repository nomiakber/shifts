class Shift < ActiveRecord::Base
  include ActionView::Helpers::DateHelper

  delegate :loc_group, to: 'location'
  belongs_to :calendar
  belongs_to :repeating_event
  belongs_to :department
  belongs_to :user
  belongs_to :location
  has_one :report, dependent: :destroy
  has_many :sub_requests, dependent: :destroy
  has_many :shifts_tasks
  has_many :tasks, through: :shifts_tasks
  before_update :disassociate_from_repeating_event

  validates_presence_of :location
  validates_presence_of :start
  validate :is_within_calendar

  before_save :set_active
  attr_accessor :start_date
  attr_accessor :start_time
  attr_accessor :end_date
  attr_accessor :end_time

#TODO: remove all   calls except where needed for booleans
  scope :active, where(active: true)
  scope :for_user, ->(usr){ where(user_id: usr.id) }
  scope :not_for_user, ->(usr){ where("user_id != ?", usr.id) }
  scope :on_day, ->(day){ where("start >= ? and start < ?", day.beginning_of_day.utc, day.end_of_day.utc) }
  scope :on_days, ->(start_day, end_day){ where("start  >= ? and start < ?",start_day.beginning_of_day.utc , end_day.end_of_day.utc) }
  scope :between, ->(start, stop){ where("start  >= ? and start  < ?", start.utc, stop.utc) }
  scope :overlaps, ->(start, stop){ where("end > ? and start  < ?", start.utc, stop.utc) }
  scope :in_department, ->(dept){ where(department_id: dept.id) }
  scope :in_departments, ->(dept_array){ where(department_id: dept_array.collect(&:id)) }
  scope :in_location, ->(loc){ where(location_id: loc.id) }
  scope :in_locations, ->(loc_array){ where(location_id: loc_array) }
  scope :in_calendars, ->(calendar_array){ where(calendar_id: calendar_array) }
  scope :scheduled, where(scheduled: true)
  scope :unscheduled, where(scheduled: false)
  scope :super_search, ->(start, stop, incr, locs){ where("( (start >= ? and start < ?) or (end > ? and end <= ?) ) and scheduled  = ? and location_id IN ?", start.utc, stop.utc - incr, start.utc + incr, stop.utc, true, locs).order("location_id , start") }
  scope :hidden_search, ->(start, stop, day_start, day_end, locs){ where("( (start >= ? and end < ?) or (start >= ? and start < ?) ) and scheduled = ? and location_id IN (?)", day_start.utc, start.utc, stop.utc, day_end.utc, true, locs).order("location_id  , start  ") }
  scope :signed_in, ->(department){where(signed_in: true, department_id: department.id)}
  scope :ordered_by_start, order('start')
  scope :after_date, ->(start_day){ where("end >= ?", start_day.beginning_of_day.utc) }
  scope :stats_unsent, where(stats_unsent: true)
  scope :stale_shifts_unsent, where(stale_shifts_unsent: true)
  scope :parsed, where(parsed: true)
  scope :unparsed, where(parsed: false)
  scope :missed, where(parsed: true, missed: true)
  scope :late, where(parsed: true, late: true)
  scope :left_early, where(parsed: true, left_early: true)


  #TODO: clean this code up -- maybe just one call to shift.scheduled?
  validates_presence_of :end, if: Proc.new{|shift| shift.scheduled?}
#  before_validation :adjust_end_time_if_in_early_morning, if: Proc.new{|shift| shift.scheduled?}
  validate :start_less_than_end, if: Proc.new{|shift| shift.scheduled?}
  validate :shift_is_within_time_slot, if: Proc.new{|shift| shift.scheduled?}
  validate :user_does_not_have_concurrent_shift, if: Proc.new{|shift| shift.scheduled?}
  validate :not_in_the_past, if: Proc.new{|shift| shift.scheduled?}, on: :create
  validate :restrictions
  validate :does_not_exceed_max_concurrent_shifts_in_location, if: Proc.new{|shift| !shift.power_signed_up?}
  validate :obeys_signup_priority
  before_save :adjust_sub_requests
  after_save :combine_with_surrounding_shifts #must be after, or reports can be lost

  # ==================
  # = Class  methods =
  # ==================

  def self.delete_part_of_shift(shift, start_of_delete, end_of_delete)
    #Used for taking sub requests
    if !(start_of_delete.between?(shift.start, shift.end) && end_of_delete.between?(shift.start, shift.end))
      raise "You can\'t delete more than the entire shift"
    elsif start_of_delete >= end_of_delete
      raise "Start of the deletion should be before end of deletion"
    elsif start_of_delete == shift.start && end_of_delete == shift.end
      shift.destroy
    elsif start_of_delete == shift.start
      shift.start=end_of_delete
      shift.save(validate: false)
    elsif end_of_delete == shift.end
      shift.end=start_of_delete
      shift.save(validate: false)
    else
      later_shift = shift.dup
      later_shift.user = shift.user
      later_shift.location = shift.location
      shift.end = start_of_delete
      later_shift.start = end_of_delete
      shift.save(validate: false)
      later_shift.save(validate: false)
      shift.sub_requests.each do |s|
        if s.start >= later_shift.start
          s.shift = later_shift
          s.save!
        end
      end
    end
  end


  # This method takes a list of shifts and deletes them, all their subrequests.
  # Necessary for conflict
  # wiping in repeating_event and calendars, as well as wiping a date range -Mike
  def self.mass_delete_with_dependencies(shifts_to_erase)
    array_of_shift_arrays = shifts_to_erase.batch(450)
    array_of_shift_arrays.each do |shifts|
      subs_to_erase = SubRequest.where(shifts.collect{|shift| "(shift_id = #{shift.id})"}.join(" OR "))
      array_of_sub_arrays = subs_to_erase.batch(450)
      array_of_sub_arrays.each do |subs|
        SubRequest.delete_all([subs.collect{|sub| "(id = #{sub.id})"}.join(" OR ")])
      end
      Shift.delete_all([shifts.collect{|shift| "(id = #{shift.id})"}.join(" OR ")])
    end
  end


  def self.make_future(event, location, wipe)
    cal = event.calendar
    if cal.active 
      shift_scope = Shift.active
    else
      shift_scope = Shift.where(calendar_id: cal.id)
    end
    dept = location.department
    user_id = event.user_id
    dates = event.dates_array
    table = Shift.arel_table
    shifts_all = Array.new
    duration = event.end_time - event.start_time
    conflict_all = nil
    dates.each do |date|
      start_time_on_date = date.to_time + event.start_time.seconds_since_midnight
      end_time_on_date = start_time_on_date + duration
      shifts_all << Shift.new(power_signed_up: true, repeating_event_id: event.id, location_id: location.id, calendar_id: cal.id, start: start_time_on_date, end: end_time_on_date, user_id: user_id, department_id: dept.id, active: cal.active)
    end
    conflict_msg = Shift.check_for_conflicts(shifts_all, wipe, shift_scope)
    if conflict_msg.empty?
      if shifts_all.map(&:valid?).all?
        Shift.import shifts_all
        return false
      else
        invalid_shifts = shifts_all.select{|s| !s.valid?}
        return invalid_shifts.map{|s| "#{s.to_message_name}: #{s.errors.full_messages.join('; ')}"}.join('. ')
      end
    else
      return conflict_msg + " have conflict. Use wipe to fix."
    end
  end

  def self.check_for_conflicts(shifts, wipe, shift_scope)
    return "" if shifts.empty?
    table = Shift.arel_table
    shifts_with_conflict = Array.new
    shifts.each_slice(450) do |shs|
      conflict_all = nil
      shs.each do |s|
        conflict_condition = table[:user_id].eq(s.user_id).and(table[:department_id].eq(s.department_id)).and(table[:start].lt(s.end)).and(table[:end].gt(s.start))
        if conflict_all.nil?
          conflict_all = conflict_condition
        else
          conflict_all = conflict_all.or(conflict_condition)
        end
      end
      shifts_with_conflict = shifts_with_conflict + shift_scope.where(conflict_all)
      shifts_with_conflict.uniq!
    end
    if wipe
      Shift.mass_delete_with_dependencies(shifts_with_conflict)
    elsif !shifts_with_conflict.empty?
      return shifts_with_conflict.map{|s| "The shift for #{s.to_message_name}."}.join(',')
    end
    return ""
  end


  # ==================
  # = Object methods =
  # ==================

  def css_class(current_user = nil)
    if current_user and self.user == current_user
      css_class = "user"
    else
      css_class = "shift"
    end
    if missed?
      css_class += "_missed"
    elsif (self.report.nil? ? Time.now : self.report.arrived) > start + department.department_config.grace_period*60 #seconds
      css_class += "_late"
    end
    css_class
  end

  def type
    if self.start <= Time.now
      if self.missed
        return "Missed"
      end

      if late? && left_early?
        return "Late & Left Early"
      elsif self.late
        return "Late"
      elsif self.left_early
        return "Left Early"
      end
      return "Completed"
    else
      return "Future"
    end
  end

  def too_early?
    self.start > 30.minutes.from_now
  end

  #Return either the actual (worked) duration of a shift, or the scheduled duration
  def duration(actual = false)
    (actual && self.report) ? self.report.duration : ((self.end - self.start)/3600 rescue 0)
  end

  def missed?
    self.has_passed? and !self.report
  end

  def late?
    self.report.nil? ? false : (self.report.arrived - self.start > self.department.department_config.grace_period*60)
  end

  def left_early?
    (self.report.nil? or self.report.departed.nil?) ? false : (self.end - self.report.departed > self.department.department_config.grace_period*60)
  end

  def updates_per_hour
    if self.report == nil
      return nil
    else
      shift_time = (self.report.departed - self.report.arrived)/3600
      if shift_time == 0
        return nil
      end
      number_report_items = self.report.report_items.size
      return number_report_items/shift_time
    end
  end

  #a shift has been signed in to if it has a report
  # NOTE: this evaluates whether a shift is CURRENTLY signed in
  def signed_in?
    self.report && !self.report.departed
  end

  #a shift has been submitted if its shift report has been submitted
  def submitted?
    self.report.nil? ? false : !self.report.departed.nil?
  end

  #a shift is stale if it is currently signed into and if the report has not been updated for an hour.
  def self.stale_shifts_with_unsent_emails(department = current_department)
    @shifts = Shift.in_department(department).signed_in(department).between(1.day.ago, Time.now).stale_shifts_unsent
    @shifts.select{|s| s.report.report_items.last.time < 1.hour.ago.utc}
  end

  #TODO: subs!
  #check if a shift has a *pending* sub request and that sub is not taken yet
  def has_sub?
    #note: if the later part of a shift has been taken, self.sub still returns true so we also need to check self.sub.new_user.nil?
    !self.sub_requests.empty? #and sub.new_user.nil? #new_user in sub is only set after sub is taken.  shouldn't check new_shift bcoz a shift can be deleted from db. -H
  end

  def has_passed?
    self.end.nil? ? false : self.end < Time.now
  end

  def has_started?
    self.start < Time.now
  end

  # If new shift runs up against another compatible shift, combine them and save,
  # preserving the earlier shift's information
  def combine_with_surrounding_shifts
    if (shift_later = Shift.where("start = ? AND user_id = ? AND location_id = ? AND calendars.active = ?", self.end, self.user_id, self.location_id, self.calendar.active?).includes(:calendar).first) && (!shift_later.has_sub?)
          if (self.report.nil? || self.report.departed.nil?) && (shift_later.report.nil?)
            self.end = shift_later.end
            shift_later.sub_requests.each { |s| s.shift = self }
            shift_later.destroy
            self.save(validate: false)
          end
        end
        if (shift_earlier = Shift.where("end = ? AND user_id = ? AND location_id = ? AND calendars.active = ?", self.start, self.user_id, self.location_id, self.calendar.active?).includes(:calendar).first) && (!shift_earlier.has_sub?)
          if (self.report.nil?) && (shift_earlier.report.nil? || shift_earlier.report.departed.nil?)
            self.start = shift_earlier.start
            shift_earlier.sub_requests.each {|s| s.shift = self}
            unless shift_earlier.report.nil?
              shift_earlier.report.shift = nil
              shift_earlier.report.save! #we have to disassociate the report first, or it will be destroyed too
              self.report = shift_earlier.report
              shift_earlier.report = nil
            end
            self.signed_in = shift_earlier.signed_in
            shift_earlier.destroy
            self.save(validate: false)
          end
        end
  end

  def exceeds_max_staff?
    count = 0
    shifts_in_period = []
    Shift.where(location_id: self.location_id, scheduled: true).each do |shift|
      shifts_in_period << shift if (self.start..self.end).to_a.overlaps((shift.start..shift.end).to_a) && self.end != shift.start && self.start != shift.end
    end
    increment = self.department.department_config.time_increment
    time = self.start + (increment / 2)
    while (self.start..self.end).include?(time)
      concurrent_shifts = 0
      shifts_in_period.each do |shift|
        concurrent_shifts += 1 if (shift.start..shift.end).include?(time)
      end
      count = concurrent_shifts if concurrent_shifts > count
      time += increment
    end
    count + 1 > self.location.max_staff
  end


  # ===================
  # = Display helpers =
  # ===================
  def short_display
      "#{location.short_name}, #{start.to_s(:just_date)} #{time_string}"
  end

  def to_message_name
    "#{user.name} in #{location.short_name} from #{start.to_s(:am_pm_long_no_comma)} to #{self.end.to_s(:am_pm_long_no_comma)}"
  end

  def short_name
    "#{location.short_name}, #{user.name}, #{time_string}, #{start.to_s(:just_date)}"
  end

  def stats_display
     "#{start.to_s(:am_pm)} - #{self.end.to_s(:am_pm)}, #{user.name}, #{location.name}"
  end

  def stats_display_missed
     str = "#{start.to_s(:am_pm)} - #{self.end.to_s(:am_pm)}, #{user.name}, #{location.name}"
     str << " <a href='mailto:#{user.email}?cc=#{user.default_department.department_config.stats_mailer_address}&subject=Missed+#{location.short_name}+Shift+&body=Hi%20#{user.goes_by}%2C%0A%0AYou%20missed%20your%20#{location.short_name}%20shift%20this%20week.%20What%20happened%3F'>[this week]</a>".html_safe
     str << " <a href='mailto:#{user.email}?cc=#{user.default_department.department_config.stats_mailer_address}&subject=Missed+#{location.short_name}+Shift+&body=Hi%20#{user.goes_by}%2C%0A%0AYou%20missed%20your%20#{location.short_name}%20shift%20yesterday.%20What%20happened%3F'>[yesterday]</a>".html_safe
     return str.html_safe
  end

  def stats_display_late
     str = "#{self.how_much_arrived_late} late. #{self.report.id}: #{start.to_s(:am_pm)} - #{self.end.to_s(:am_pm)}, #{user.name}, #{location.name}"
     str << " <a href='mailto:#{user.email}?cc=#{user.default_department.department_config.stats_mailer_address}&subject=Late+#{location.short_name}+Shift+&body=Hi%20#{user.goes_by}%2C%0A%0AYou%20were%20late%20to%20your%20#{location.short_name}%20shift%20this%20week.%20What%20happened%3F%0A%0A%0ADeCaL'>[this week]</a>".html_safe
     str << " <a href='mailto:#{user.email}?cc=#{user.default_department.department_config.stats_mailer_address}&subject=Late+#{location.short_name}+Shift+&body=Hi%20#{user.goes_by}%2C%0A%0AYou%20were%20late%20to%20your%20#{location.short_name}%20shift%20yesterday.%20What%20happened%3F%0A%0A%0ADeCaL'>[yesterday]</a>".html_safe
     return str.html_safe
  end

  def stats_display_left_early
     str = "#{self.how_much_left_early} early. #{self.report.id}: #{start.to_s(:am_pm)} - #{self.end.to_s(:am_pm)}, #{user.name}, #{location.name}"
     str << " <a href='mailto:#{user.email}?cc=#{user.default_department.department_config.stats_mailer_address}&subject=Left+Early+From+#{location.short_name}+Shift+&body=Hi%20#{user.goes_by}%2C%0A%0AYou%20left%20your%20#{location.short_name}%20shift%20early%20this%20week.%20What%20happened%3F%0A%0A%0ADeCaL'>[this week]</a>".html_safe
     str << " <a href='mailto:#{user.email}?cc=#{user.default_department.department_config.stats_mailer_address}&subject=Left+Early+From+#{location.short_name}+Shift+&body=Hi%20#{user.goes_by}%2C%0A%0AYou%20left%20your%20#{location.short_name}%20shift%20early%20yesterday.%20What%20happened%3F%0A%0A%0ADeCaL'>[yesterday]</a>".html_safe
     return str.html_safe
  end

  def how_much_arrived_late
    distance_of_time_in_words(self.report.arrived, self.start)
  end

  def how_much_left_early
    distance_of_time_in_words(self.end, self.report.departed)
  end

  def name_and_time
    "#{user.name}, #{time_string}"
  end

  def name_date_and_time
    "#{user.name}, #{start.to_s(:just_date)}, #{start.to_s(:am_pm)}"
  end

  def time_string
    scheduled? ? "#{start.to_s(:am_pm)} - #{self.end.to_s(:am_pm)}" : "unscheduled"
  end

  def task_time
    scheduled? ? "#{start.to_s(:am_pm)} - #{self.end.to_s(:am_pm)}" : "unscheduled (#{start.to_s(:am_pm)} - #{self.end.to_s(:am_pm)})"

  end

  def sub_request
    SubRequest.where(shift_id: self.id).first
  end




  # ======================
  # = Validation helpers =
  # ======================

  private

  def restrictions
    unless self.power_signed_up
      errors.add(:user, "is required") and return if self.user.nil?
      self.user.restrictions.each do |restriction|
        if restriction.max_hours
          relevant_shifts = Shift.between(restriction.starts,restriction.expires).for_user(self.user)
          hours_sum = relevant_shifts.map{|shift| shift.end - shift.start}.flatten.sum / 3600.0
          hours_sum += (self.end - self.start) / 3600.0
          if hours_sum > restriction.max_hours
            errors.add(:max_hours, "have been exceeded by #{hours_sum - restriction.max_hours}.")
          end
        end
      end
      self.location.restrictions.each do |restriction|
        if restriction.max_hours
          relevant_shifts = Shift.between(restriction.starts,restriction.expires).in_location(self.location)
          hours_sum = relevant_shifts.map{|shift| shift.end - shift.start}.flatten.sum / 3600.0
          hours_sum += (self.end - self.start) / 3600.0
          if hours_sum > restriction.max_hours
            errors.add(:max_hours, "have been exceeded by #{hours_sum - restriction.max_hours}.")
          end
        end
      end
    end
  end

  def start_less_than_end
    errors.add(:start, "must be earlier than end time") if (self.end <= self.start)
  end

  #TODO: Fix this to check timeslots by time_increment
  def shift_is_within_time_slot
    unless self.power_signed_up
      if (self.calendar.default || self.calendar.active)
        c = TimeSlot.where("location_id = ? AND start <= ? AND end >= ? AND active  = ?", self.location_id, self.start, self.end, true).count
      else
        #If users are signing up into a non-active calendar, we want to make sure we still respect the (non-active) timeslots present in that calendar
        c = TimeSlot.where("location_id = ? AND start <= ? AND end >= ? AND calendar_id = ?", self.location_id, self.start, self.end, self.calendar_id).count
      end
      errors.add(:base, "You can only sign up for a shift during a time slot.") if c == 0
    end
  end

  def user_does_not_have_concurrent_shift
    c = Shift.for_user(self.user).in_department(self.department).overlaps(self.start, self.end)
    if self.calendar.active
      c = c.active
    else
      c = c.in_calendars(self.calendar)
    end
    unless c.empty?
      errors.add(:base, "#{self.user.name} has an overlapping shift in that period.") unless (c.length == 1  and  self.id == c.first.id)
    end
  end

  def not_in_the_past
    errors.add(:base, "Can't sign up for a shift that has already passed.") if self.start <= Time.now
  end

  def does_not_exceed_max_concurrent_shifts_in_location
    if self.scheduled?
      max_concurrent = self.location.max_staff
      shifts = Shift.active.scheduled.in_location(self.location).overlaps(self.start, self.end)
      shifts.delete_if{|shift| shift.id = self.id} unless self.new_record?
      time_increment = self.department.department_config.time_increment

      #how many people are in this location?
      people_count = {}
      people_count.default = 0
      unless shifts.nil?
        shifts.each do |shift|
          time = shift.start
          time = time.hour*60+time.min
          end_time = shift.end
          end_time = end_time.hour*60+end_time.min
          while (time < end_time)
            people_count[time] += 1
            time += time_increment
          end
        end
      end

      errors.add(:base, "#{self.location.name} only allows #{max_concurrent} concurrent shifts.") if people_count.values.select{|n| n >= max_concurrent}.size > 0
    end
  end

  def obeys_signup_priority

    return if (self.power_signed_up || !self.scheduled || !self.calendar.active)

    #check for all higher-priority locations in this loc group
    prioritized_locations = self.loc_group.locations.select{|l| l.priority > self.location.priority}
    seconds_increment = self.department.department_config.time_increment * 60
    prioritized_locations.each do |prioritized_location|
      min_staff_filled = true

      time = self.start
      end_time = self.end
      while (time < end_time)
        people_count = Shift.active.scheduled.in_location(prioritized_location).overlaps(time, (time + seconds_increment)).count
        time_slot_present = TimeSlot.active.in_location(prioritized_location).overlaps(time, (time + seconds_increment)).count >= 1
        # if at any time the location is not at min_staff and there is a timeslot, the validation fails
        if people_count < prioritized_location.min_staff && time_slot_present
          errors.add(:base, "Signup slots in #{prioritized_location.name} are higher priority and must be filled first.")
          break
        end
        time += seconds_increment
      end
    end
  end

  #TODO: catch exceptions
  def adjust_sub_requests
    self.sub_requests.each do |sub|
      if sub.start > self.end || sub.end < self.start
        sub.destroy
      else
        sub.start = self.start if sub.start < self.start
        sub.mandatory_start = self.start if sub.mandatory_start < self.start
        sub.end = self.end if sub.end > self.end
        sub.mandatory_end = self.end if sub.mandatory_end > self.end
        sub.save(validate: false)
      end
    end
  end

  def set_active
    #self.active = self.calendar.active
    #return true
    self.active = calendar.active && location.active && user.is_active?(department)
    return true
  end

  def is_within_calendar
    unless self.calendar.default
      errors.add(:base, "Shift start and end dates must be within the range of the calendar.") if self.start.to_date < self.calendar.start_date.to_date || self.end.to_date > self.calendar.end_date.to_date
    end
  end

  def disassociate_from_repeating_event
    self.repeating_event_id = nil
  end

  def adjust_end_time_if_in_early_morning
    #increment end by one day in cases where the department is open past midnight
    self.end += 1.day if (self.end <= self.start and (self.end.hour * 60 + self.end.min) <= (self.department.department_config.schedule_end % 1440))
    #stopgap fix: don't allow shifts longer than 24 hours
    self.end -= 1.day if (self.end > self.start + 1.day)
  end

  class << columns_hash['start']
    def type
      :datetime
    end
  end
end

