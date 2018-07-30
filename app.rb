require 'sinatra'
require 'open3'
require 'time'
require 'pathname'
require 'etc'
require 'fileutils'
require 'filesize'
require 'yaml'

enable :sessions # allow displaying of alerts after redirect
use Rack::MethodOverride # enable delete route in old browsers

IDENTIFICATION_FILE = "this_is_a_homework_directory" # file found in HW directories to identify them as such
SCRIPTS_DIR = "scripts" # name of the scripts directory, found in each HW directory that holds all the assignment-related scripts
PROJECTS_DIR = "/fs/project/" # directory contataining all project folders
DATE_FILE = "meta_date_a.yaml" # file found in each assignment directory, contains creation and due dates, also serves as identification
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

AssignmentInfo = Struct.new(:path, :name, :class, :project, :open?, :submissions, :date_created, :date_due) do
	def initialize (dir_path)
		self[:path] = dir_path
		self[:name] = dir_path.basename.to_s
		self[:class] = dir_path.dirname.basename.to_s
		self[:project] = dir_path.dirname.dirname.basename.to_s
		self[:submissions] = dir_path.children.select{|x| x.directory?}	
		dates_hash = YAML.load(IO.read(dir_path + DATE_FILE))	
		self[:date_created] = Time.parse(dates_hash[:created]) rescue nil
		self[:date_due] = Time.parse(dates_hash[:due]) rescue nil # if date is not valid
		self[:open?] = (dir_path + ASSIGNMENT_OPEN_FILE).exist? 
	end
end

SubmissionInfo = Struct.new(:path, :submitter, :size, :date_submitted, :late?) do
	def initialize (dir_path, assignment_info)
		self[:path] = dir_path
		self[:submitter] = `getent passwd #{dir_path.basename.to_s} | cut -d ':' -f 5`
		self[:size] = Filesize.new(dir_size(dir_path))
		#self[:size] = `du -sh #{dir_path}`.split.first # either way this is pretty slow for big files >500MB
		self[:date_submitted] = dir_path.mtime
		date_due = assignment_info.date_due
		self[:late?] = date_due.nil? ? false : self[:date_submitted] > date_due.to_time
	end
	
	def dir_size (dir_path)
		dir_path.children.map{|c|	
			unless c.symlink?
				c.directory? ? dir_size(c) : c.size
			else
				0
			end
		}.inject {|sum, s| 
			sum + s
		}.to_i
	end
end

# Enums for possible identification states
module ID
	INSTRUCTOR = 0
	TA = 1
	STUDENT = 2

	def ID.identify (hw_dir_path)	
		if hw_dir_path.owned? 
			INSTRUCTOR
		elsif hw_dir_path.writable?
			TA
		else
			STUDENT
		end
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
	project = params[:project]
	class_name = params[:class]

	class_path = Pathname.new(PROJECTS_DIR).join(project).join(class_name)
	halt 404, "File or directory not found" unless class_path.exist?
	halt 403, "Permission denied" unless class_path.readable?
	halt 401, "Not a homework directory" unless (class_path + IDENTIFICATION_FILE).exist?

	@class_info = ClassInfo.new(class_path)
end

get '/all/:project/:class' do
	@id = ID.identify(@class_info.path)
		
	@assignment_infos = Array.new 

	@class_info.assignments.each do | a |
		@assignment_infos << AssignmentInfo.new(a)
	end	

	@assignment_infos.sort_by!{|c| c.date_created}.reverse!

	erb :class	
end

delete '/all/:project/:class' do 
	FileUtils.remove_entry_secure @class_info.path.to_s
	session[:msgs] = Message.new("success", "Class removed: directory and contents at #{@class_info.path} were deleted")
	redirect to '/all'
end

before '/all/:project/:class/:assignment' do
	assignment = params[:assignment]
	project = params[:project]
	class_name = params[:class]

	assignment_path = Pathname.new(PROJECTS_DIR).join(project).join(class_name).join(assignment)
	halt 404, "File or directory not found" unless assignment_path.exist?
	halt 403, "Permission denied" unless assignment_path.executable? # if the folder can be opened
	halt 401, "Not in a homework directory" unless (assignment_path.dirname + IDENTIFICATION_FILE).exist?

	@assignment_info = AssignmentInfo.new(assignment_path)
end

get '/all/:project/:class/:assignment' do
	@submission_infos = Array.new

	@assignment_info.submissions.each do | s |
		@submission_infos << SubmissionInfo.new(s, @assignment_info)
	end

	if params[:download]
		# relies on cron to cleanup tmp directory/file (trying to delete it here sends empty file)
		mktemp_cmd = "mktemp --directory --tmpdir='/tmp' download.XXXXXX;"
 
		stdout, stderr, status = Open3.capture3(mktemp_cmd);
		halt 500, "could not create temporary file for downloading: #{stderr}" unless status.success?
		tmp_dirpath = Pathname.new(stdout.chomp)
		tmp_filepath = tmp_dirpath.join(@assignment_info.name).sub_ext(".zip")
	
		@submission_infos.reject!{ |s| s.late? } if params[:no_late]	
		@submission_infos.select!{ |s| s.late? } if params[:only_late]
		halt 401, "no submissions to download" if @submission_infos.empty?
		file_list = @submission_infos.map{|s| s.path.basename.to_s}

		zip_cmd = "/usr/bin/zip", "-r", tmp_filepath.to_s, *file_list
		Dir.chdir(@assignment_info.path) do
			stdout, stderr, status = Open3.capture3(*zip_cmd)
			halt 500, "could not compress submissions for download: #{stderr}" unless status.success?
		end

		send_file tmp_filepath.to_s, :filename => tmp_filepath.basename.to_s	
	else		
		@submission_infos.sort_by!{|s| s.submitter.downcase}
		erb :assignment
	end
end

# for editing assignment config
post '/all/:project/:class/:assignment' do
	if params[:modify_lock?]	
		lock_file_path = @assignment_info.path.join(ASSIGNMENT_OPEN_FILE)
		if lock_file_path.exist?
			lock_file_path.delete
			redirect_back_with_msg("danger", "Assignment #{@assignment_info.name} has been locked and will not recieve any further submissions")
		else
			File.new(lock_file_path.to_s, "w")
			redirect_back_with_msg("success", "Assignment #{@assignment_info.name} has been unlocked and is open to submissions")
		end
	
	elsif params[:modify_due?]
		date_file_path = @assignment_info.path.join(DATE_FILE)
		begin
			date_hash = YAML.load(IO.read(date_file_path))
			new_due_date = Time.parse("#{params[:time_due]} #{params[:date_due]}").to_s unless params[:date_due].empty? rescue nil
			date_hash[:due] = new_due_date
			IO.write(date_file_path, date_hash.to_yaml)
		rescue => e
			redirect_back_with_msg("danger", "Could not modify due date: #{e.message}")
		end
	end
	redirect back
end

delete '/all/:project/:class/:assignment' do
	FileUtils.remove_entry_secure @assignment_info.path.to_s
	session[:msgs] = Message.new("success", "Assignment removed: directory/contents at #{@assignment_info.path} were deleted")
	redirect to "/all/#{@assignment_info.project}/#{@assignment_info.class}"
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

	date_due = Time.parse("#{params[:time_due]} #{params[:date_due]}").to_s unless params[:date_due].empty? rescue nil

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
