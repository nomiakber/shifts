class UserMailer < ActionMailer::Base
  default from: "noreply@shifts.app"

  def registration_confirmation(user)
    @dept = user.default_department
    mail(to: user.email, subject: "Registered")
  end

  ## SHIFTS

  def shift_report(shift, report, dept)
    #If a profile field for queue exists, include it in subject
    queue_text = ""
    if queue_field = UserProfileField.where(name: "Queue").first
      user = shift.user
      profile_entry = UserProfileEntry.where(
                                  user_profile_id: user.user_profile.id,
                                  user_profile_field_id: queue_field.id).first
      user_queue = profile_entry.content if profile_entry
      queue_text = user_queue ? "(User Queue: #{user_queue})" : ""
    end
    @shift = shift
    @report = report
    mail( to:       shift.user.email,
          from:     shift.user.email,
          cc:       shift.location.try(:report_email),
          subject:  "Shift Report: #{shift.short_display} #{queue_text}",
          date:     Time.now)
  end

  #an email is sent to a student if they have been inactive in their shift for an hour
  def stale_shift(user, stale_shift, dept)
    @user = user
    @stale_shift = stale_shift
    mail(to: "#{user.name} <#{user.email}>", from: dept.department_config.mailer_address,
      subject: "Your Shift in the #{stale_shift.location.name} has been inactive for at least an hour.", date: Time.now)
  end

  # SUB REQUEST
  # email the specified list or default list of eligible takers
  def sub_created_notify(user, sub)
    @sub = sub
    mail(to: "#{user.name} <#{user.email}>", from: sub.user.email,
      subject: "[Sub Request] Sub needed for " + sub.shift.short_display, date: Time.now)
  end

  #email a group of users who want to see whenever a sub request is taken
  def sub_taken_watch(user, owner, new_shift, email_start, email_end, dept, disp)
    @owner = owner
    @new_shift = new_shift
    @email_start = email_start
    @email_end = email_end
    mail(to: "#{user.name} <#{user.email}>", from: owner.email,
      subject: "Re: [Sub Request] Sub needed for " + disp, date: Time.now)
  end

  #email the user who took the sub and the requester of the sub that their shift has been taken
  def sub_taken_notification(owner, new_shift, dept)
    @owner = owner
    @new_shift = new_shift
    mail(to: @owner.email, 
         from: dept.department_config.mailer_address, 
         cc: new_shift.user.email,
         subject: "[Sub Request] #{new_shift.user.name} took your sub!", 
         date: Time.now)
  end

  ## PAYFORMS

  def payform_item_modify_notification(new_payform_item, dept)
  	@new_payform_item = new_payform_item
    @dept = dept
  	mail(to: new_payform_item.user.email, from: dept.department_config.mailer_address,
  		subject: "Your payform has been modified by #{new_payform_item.originator}", date: Time.now)
  end

  def payform_item_deletion_notification(old_payform_item, dept)
    @old_payform_item = old_payform_item
    @dept = dept
    mail(to: old_payform_item.user.email, from: dept.department_config.mailer_address,
    	subject: "Your payform item has been deleted by #{old_payform_item.originator}", date: Time.now)
  end

  # Beginning of payform notification methods

  def due_payform_reminder(user, message, dept)
    @user = user
    @message = message
    @dept = dept
    mail(to: "#{user.name} <#{user.email}>", from: "#{dept.department_config.mailer_address}",
      subject: "Due Payforms Reminder", date: Time.now)
  end

  def late_payform_warning(user, message, dept, unsubmitted_payform_ids)
    @user = user
    @message = message
    @dept = dept
    @payforms = unsubmitted_payform_ids.map{|id| Payform.find(id)}
    mail(to: "#{user.name} <#{user.email}>", from: "#{dept.department_config.mailer_address}",
      subject: "Late Payform Warning", date: Time.now)
  end

  #this code is currently not used anywhere in the code so Adam told me to comment it out for now. - Maria
  # def printed_payforms_notification(admin_user, message, attachment_name)
  #   subject       'Printed Payforms ' + Date.today.strftime('%m/%d/%y')
  #   recipients    "#{admin_user.email}"
  #   from          "#{dept.department_config.mailer_address}"
  #   sent_on       Time.now
  #   content_type  'text/plain'
  #   body        message: message
  #   attachment  content_type: "application/pdf",
  #               body:         File.read("data/payforms/" + attachment_name),
  #               filename:     attachment_name
  # end

  ## EMAILING STATS

  #email notifies admin that a shift has been missed, was signed into late, or was left early
  def email_stats(missed_shifts, late_shifts, left_early_shifts, dept)
    @missed_shifts = missed_shifts.map{|id| Shift.find(id)}
    @late_shifts = late_shifts.map{|id| Shift.find(id)}
    @left_early_shifts = left_early_shifts.map{|id| Shift.find(id)}
    mail(to: dept.department_config.stats_mailer_address, from: dept.department_config.mailer_address,
      subject: "Shift Statistics for #{dept.name}:" + (Time.now - 86400).strftime('%m/%d/%y'), date: Time.now) #this assumes that the email is sent the day after the shifts (ex. after midnight) so that the email captures all of the shifts
  end




  ## BUILT-IN AUTHORIZATION (Not supported yet)

  def password_reset_instructions(user)
    @edit_password_reset_url = edit_password_reset_url(user.perishable_token)
    mail(to: user.email, subject: "Password Reset Instructions",
      date: Time.now)
  end

  def admin_password_reset_instructions(user)
    @edit_admin_password_reset_url = edit_password_reset_url(user.perishable_token)
    mail(to: user.email, subject: "Password Reset Instructions",
      date: Time.now)
  end

  def new_user_password_instructions(user, dept)
    @edit_new_user_password_url = edit_password_reset_url(user.perishable_token)
    @user = user
    @dept = dept
    mail(to: user.email, from: dept.department_config.mailer_address,
    	subject: "Password Creation Instructions", date: Time.now)
  end

  #For use when users are imported from csv
  def new_user_password_instructions_csv(user, dept)
    @edit_new_user_password_url = edit_password_reset_url(user.perishable_token)
    mail(to: user.email, from: AppConfig.first.mailer_address,
      subject: "Password Creation Instructions", date: Time.now)
  end

  def change_auth_type_password_reset_instructions(user)
    @edit_password_url = edit_password_reset_url(user.perishable_token)
    mail(to: user.email, subject: "Password Creation Instructions",
    	date: Time.now)
  end

end
