class AnnouncementsController < NoticesController
  layout 'shifts'

	before_filter :require_any_loc_group_admin, except: [:index, :show]

  def index
    flash.keep
    redirect_to(notices_path)
  end

  def show
    flash.keep
 		redirect_to(notices_path)
  end

  def new
		@current_shift_location = current_user.current_shift.location if current_user.current_shift
    @announcement = Announcement.new
    layout_check
  end

  def edit
    @announcement = Announcement.find(params[:id])
		layout_check
  end

  def create
    parse_date_and_time_output(params[:announcement])
    join_date_and_time(params[:announcement])
    @announcement = Announcement.new(params[:announcement])
		set_author_dept_and_time
		@current_shift = current_user.current_shift

    Announcement.transaction do
      @announcement.save(validate: false)
      set_sources(@announcement)
      @announcement.save!
      @current_notices = current_department.current_notices
  	end

		flash[:notice] = 'Announcement was successfully created.'
    respond_to do |format|
      format.html { redirect_to announcements_path }
      format.js  #create.js.erb
    end

    rescue Exception
      respond_to do |format|
        format.html { render action: "new" }
        format.js  #create.js.erb
    end
  end

  def update
    @announcement = Announcement.find(params[:id]) || Announcement.new
    parse_date_and_time_output(params[:announcement])
    join_date_and_time(params[:announcement])
		@announcement.update_attributes(params[:announcement])
		set_author_dept_and_time
		current_user.current_shift ? @current_shift = current_user.current_shift : nil
    begin
      Announcement.transaction do
        @announcement.save(validate: false)
        set_sources(@announcement)
        @announcement.save!
        @current_notices = current_department.current_notices
      end
    rescue Exception
        respond_to do |format|
          format.html { render action: "new" }
					format.js
        end
      else
        respond_to do |format|
        flash[:notice] = 'Announcement was successfully saved.'
        format.html {
          redirect_to action: "index"
        }
				format.js
      end
    end
  end

	private
	def set_author_dept_and_time
		@announcement.author = current_user
		@announcement.department = current_department
#    @announcement.start = Time.now if params[:start_time_choice] == "now"
    @announcement.start = Time.now
		if params[:end_time_choice] == "indefinite"
    	@announcement.end = nil
    	@announcement.indefinite = true
		end
	end
end
