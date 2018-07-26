require 'sinatra'
require 'open3'
require 'date'
require 'pathname'
require 'etc'
require 'fileutils'

enable :sessions # allow displaying of alerts after redirect
use Rack::MethodOverride # enable delete route in old browsers

IDENTIFICATION_FILE = "this_is_a_homework_directory" # file found in HW directories to identify them as such
SCRIPTS_DIR = "scripts" # name of the scripts directory, found in each HW directory that holds all the assignment-related scripts
PROJECTS_DIR = "/fs/project/" # directory contataining all project folders
DATE_FILE = "meta_date_a" # file found in each assignment directory, contains creation and due dates, also serves as identification
ASSIGNMENT_OPEN_FILE = "rm_me_to_lock_assignment" # file found in assignment directory if assignment is open for submission

ClassInfo = Struct.new(:path, :name, :project, :instructor, :assignments, :submissions, :date_created) do
	def initialize (hw_dir_path)
		self[:path] = hw_dir_path
		self[:name] = hw_dir_path.basename.to_s
		self[:project] = hw_dir_path.dirname.basename.to_s
		self[:instructor] = `getent passwd #{hw_dir_path.stat.uid} | cut -d ':' -f 5`.chomp
		self[:assignments] = hw_dir_path.children.select{|a| (a + DATE_FILE).exist?}
		self[:submissions] = self[:assignments].flat_map{|a| a.children}.select{|x| x.directory?} 
		self[:date_created] = (hw_dir_path + IDENTIFICATION_FILE).mtime
	end
end

AssignmentInfo = Struct.new(:path, :name, :open?, :submissions, :date_created, :date_due) do
	def initialize (dir_path)
		self[:path] = dir_path
		self[:name] = dir_path.basename.to_s
		self[:submissions] = dir_path.children.select{|x| x.directory?}	
		line1, line2 = IO.readlines((dir_path + DATE_FILE).to_s, chomp: true)
		self[:date_created] = DateTime.parse(line1.split("Created: ").last)
		self[:date_due] = DateTime.parse(line2.split("Due: ").last) rescue nil # if date is not valid
		self[:open?] = (dir_path + ASSIGNMENT_OPEN_FILE).exist? 
	end
end

SubmissionInfo = Struct.new(:submitter, :size, :date_submitted) do
	def initialize (dir_path)
		self[:submitter] = `getent passwd #{dir_path.basename.to_s} | cut -d ':' -f 5`
		self[:size] = 0
		self[:date_submitted] = dir_path.mtime
	end
end

Message = Struct.new(:type, :text) # type corresponds to bootstrap theme colors: success, danger, warning, info

helpers do
	def redirect_back_with_msg(type, text)
		session[:msgs] = Message.new(type, text)
		redirect back	
	end
end

before '/all*' do
	@msgs = Array.new # store any Messages that need to be displayed (i.e errors)
	@msgs.push session.delete(:msgs) unless session[:msgs].nil?	
end

get '/' do
	redirect to '/all'
end

get '/all' do
	@class_infos = Array.new # store ClassInfo objects
	@project_paths = Array.new

	# get groups
	stdout_str, stderr_str, status = Open3.capture3("groups")
	@msgs << Message.new("danger", "could not identify user's groups (groups)") unless status.success?
	groups = stdout_str.chomp.split
	
	# look for project directories under /fs/project/
	groups.each do | g |
		path = Pathname.new(PROJECTS_DIR).join(g)
		@project_paths << path if path.directory?
	end
		
	@msgs << Message.new("danger", "user does have access to any project directories") if @project_paths.empty?

	# look for hw directories in the project directories
	@project_paths.each do | pp |
		Pathname.glob(pp + "*" + IDENTIFICATION_FILE) do | p |
			hw_dir_path = p.dirname	
			@class_infos << ClassInfo.new(hw_dir_path)
		end
	end

	@class_infos.sort_by!{|c| c.date_created}.reverse!
	
	erb :index
end

get '/all/:project' do
	@class_infos = Array.new
	@project = params[:project]

	@project_path = Pathname.new(PROJECTS_DIR).join(@project)
	halt 404, "File or directory not found" unless @project_path.exist?
	halt 403, "Permission denied" unless @project_path.readable?

	Pathname.glob(@project_path + "*" + IDENTIFICATION_FILE) do | p |
		hw_dir_path = p.dirname
		@class_infos << ClassInfo.new(hw_dir_path)
	end

	@class_infos.sort_by!{|c| c.date_created}.reverse!

	erb :project
end

before '/all/:project/:class' do
	@project = params[:project]
	@class = params[:class]

	@class_path = Pathname.new(PROJECTS_DIR).join(@project).join(@class)
	halt 404, "File or directory not found" unless @class_path.exist?
	halt 403, "Permission denied" unless @class_path.readable?
	halt 401, "Not a homework directory" unless (@class_path + IDENTIFICATION_FILE).exist?
end

get '/all/:project/:class' do
	@assignment_infos = Array.new 

	Pathname.glob(@class_path + "*" + DATE_FILE) do | p |
		assign_path = p.dirname	
		@assignment_infos << AssignmentInfo.new(assign_path)
	end	

	@assignment_infos.sort_by!{|c| c.date_created}.reverse!

	erb :class	
end

delete '/all/:project/:class' do 
	FileUtils.remove_entry_secure @class_path.to_s
	session[:msgs] = Message.new("success", "Class removed: directory and contents at #{@class_path} were deleted")
	redirect to '/all'
end

before '/all/:project/:class/:assignment' do
	@assignment = params[:assignment]
	@project = params[:project]
	@class = params[:class]

	@assignment_path = Pathname.new(PROJECTS_DIR).join(@project).join(@class).join(@assignment)
	halt 404, "File or directory not found" unless @assignment_path.exist?
	halt 401, "Not in a homework directory" unless (@assignment_path.dirname + IDENTIFICATION_FILE).exist?
end

get '/all/:project/:class/:assignment' do
	if @assignment_path.readable? # if user is the instructor
		@submission_infos = Array.new

		@assignment_path.each_child do | p |
			@submission_infos << SubmissionInfo.new(p) if p.directory?
		end
	
		@submission_infos.sort_by!{|s| s.submitter.downcase}

		erb :assignment
	end
end

# for locking/unlocking assignments
post '/all/:project/:class/:assignment' do
	if params[:modify_lock?]	
		lock_file_path = @assignment_path.join(ASSIGNMENT_OPEN_FILE)
		if lock_file_path.exist?
			lock_file_path.delete
			redirect_back_with_msg("danger", "Assignment #{@assignment} has been locked and will not recieve any further submissions")
		else
			File.new(lock_file_path.to_s, "w")
			redirect_back_with_msg("success", "Assignment #{@assignment} has been unlocked and is open to submissions")
		end
	end
	redirect back
end

delete '/all/:project/:class/:assignment' do
	FileUtils.remove_entry_secure @assignment_path.to_s
	session[:msgs] = Message.new("success", "Assignment removed: directory and contents at #{@assignment_path} were deleted")
	redirect to "/all/#{@project}/#{@class}"
end

get '/download/*' do | glob |
	pn = Pathname.new(PROJECTS_DIR).join(glob)
	halt 404, "File or directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.readable?

	if pn.file?

		send_file pn

	elsif pn.directory?

		# relies on cron to cleanup tmp directory/file (trying to delete it here sends empty file)
		mktemp_cmd = "mktemp --directory --tmpdir='/tmp' download.XXXXXX;"
 
		stdout, stderr, status = Open3.capture3(mktemp_cmd);
		halt 500, "could not create temporary file for downloading: #{stderr}" unless status.success?

		@tmp_dirpath = Pathname.new(stdout.chomp)
		tmp_filepath = @tmp_dirpath.join(pn.basename).sub_ext(".zip")
	
		zip_cmd = "/usr/bin/zip", "-r", tmp_filepath.to_s, pn.basename.to_s
		
		Dir.chdir(pn.dirname.to_s) do	 # prevents saving entire folder path in zip
			stdout, stderr, status = Open3.capture3(*zip_cmd)
			halt 500, "could not compress directory: #{stderr}" unless status.success?
		end

		send_file tmp_filepath.to_s, :filename => tmp_filepath.basename.to_s

	else
		halt 400, "Not a file or directory"
	end
end

post '/submit/assignment' do
	hw_dir_path = Pathname.new(params[:hw_dir])
	script_path = hw_dir_path.join("scripts").join("submit_hw_helper")
	assignment_name = params[:assignment_name]
	source_path = Pathname.new(params[:source_path])

	halt 401, "Not a homework directory" unless (hw_dir_path + IDENTIFICATION_FILE).exist?
	halt 500, "Could not find/access script" unless script_path.executable?
	
	redirect_back_with_msg("danger", "Homework not submitted: source directory not found") unless source_path.exist?
	redirect_back_with_msg("danger", "Homework not submitted: no permission to read source") unless source_path.readable?
	
	dir = Dir.mktmpdir
	
	begin
		FileUtils.cp_r source_path.to_s, dir
	rescue
		FileUtils.remove_entry dir
		redirect_back_with_msg("danger", "Homework not submitted: could not copy all files from source")
	end

	instructor = `stat -c '%U' #{hw_dir_path}`.chomp
	setfacl_cmd = "/usr/bin/setfacl -R -m 'u:#{instructor}:r' #{dir}"
	stdout, stderr, status = Open3.capture3(setfacl_cmd)

	unless status.success?
		FileUtils.remove_entry dir
		redirect_back_with_msg("danger", "Failed to submit homeowrk: failed to set facl on the file system: #{stderr}")
	end		

	submit_cmd = script_path.to_s, assignment_name.to_s, source_path.to_s
	stdout, stderr, status = Open3.capture3(*submit_cmd)
	
	FileUtils.remove_entry dir
	redirect_back_with_msg("danger", "Failed to submit homework: #{stdout}") unless status.success?
	redirect_back_with_msg("success", "Homework successfully submitted for assignment '#{assignment_name}'.")
end

post '/add/class' do
	pn = Pathname.new(params[:parent_dir])	
	class_name = params[:class_name]
	script_pn = Pathname.new(".").realpath.join("hw_dir_setup")

	halt 404, "Parent directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.writable?
	halt 400, "Not a directory" unless pn.directory?
		
	redirect_back_with_msg("danger", "Invalid class name: '#{class_name}'") unless class_name.match /\A\w+$\z/	
	redirect_back_with_msg("danger", "Internal error: could not access script") unless script_pn.exist?

	hw_dir_setup_cmd = "#{script_pn} #{class_name} #{pn.basename}"	

	# create new hw directory under project
	Dir.chdir(pn.to_s) do
		stdout, stderr, status = Open3.capture3(hw_dir_setup_cmd)
		redirect_back_with_msg("warning", "Could not add class: #{stdout}") unless status.success?		
	end
	
	redirect_back_with_msg("success", "Class Added: directory for #{class_name} successfully created")
end

post '/add/assignment' do
	pn = Pathname.new(params[:hw_dir])
	assignment_name = params[:assignment_name]
	script_pn = pn.realpath.join("scripts").join("add_assignment")
	date_due = params[:date_due] + " " + params[:time_due] unless params[:date_due].empty?

	halt 404, "Parent directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.writable?
	halt 400, "Not a directory" unless pn.directory?	
	halt 401, "Not a homework directory" unless (pn + IDENTIFICATION_FILE).exist?

	redirect_back_with_msg("danger", "Invalid assignment name: '#{assignment_name}'") unless assignment_name.match /\A\w+$\z/
	redirect_back_with_msg("danger", "Internal error: could not access script") unless script_pn.exist?
	
	add_assignment_cmd = "#{script_pn} '#{assignment_name}'"
	add_assignment_cmd << " '#{date_due}'" if date_due

	stdout, stderro, status = Open3.capture3(add_assignment_cmd)	
	redirect_back_with_msg("warning", "Could not add assignment: #{stdout}") unless status.success?		

	redirect_back_with_msg("success", "Assignment #{assignment_name} has been successfully created and is open to submission")
end
