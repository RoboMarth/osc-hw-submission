require 'sinatra'
require 'open3'
require 'date'
require 'pathname'
require 'etc'

enable :sessions

IDENTIFICATION_FILE = "this_is_a_homework_directory" # file found in HW directories to identify them as such
PROJECTS_DIR = "/fs/project/" # directory contataining all project folders
DATE_FILE = "meta_date_a" # file found in each assignment directory, contains creation and due dates, also serves as identification

ClassInfo = Struct.new(:name, :project, :instructor, :assignments, :submissions, :date_created) do
	def initialize (hw_dir_path)
		self[:name] = hw_dir_path.basename.to_s
		self[:project] = hw_dir_path.dirname.basename.to_s
		self[:instructor] = `getent passwd #{hw_dir_path.stat.uid} | cut -d ':' -f 5`
		self[:assignments] = hw_dir_path.children.select{|a| (a + DATE_FILE).exist?}
		self[:submissions] = self[:assignments].flat_map{|a| a.children}.select{|x| x.directory?} 
		self[:date_created] = (hw_dir_path + IDENTIFICATION_FILE).mtime
	end
end

AssignmentInfo = Struct.new(:name, :submissions,:date_created, :date_due) do
	def initialize (dir_path)
		self[:name] = dir_path.basename.to_s
		self[:submissions] = dir_path.children.select{|x| x.directory?}	
		line1, line2 = IO.readlines((dir_path + DATE_FILE).to_s, chomp: true)
		self[:date_created] = DateTime.parse(line1.split("Created: ").last)
		self[:date_due] = DateTime.parse(line2.split("Due: ").last) rescue nil # if date is not valid
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
	@table_rows = Array.new # store ClassInfo objects
	@project_paths = Array.new

	# get groups
	stdout_str, stderr_str, status = Open3.capture3("groups")
	@msgs.push Message.new("danger", "could not identify user's groups (groups)") unless status.success?
	groups = stdout_str.chomp.split
	
	# look for project directories under /fs/project/
	groups.each do | g |
		path = Pathname.new(PROJECTS_DIR).join(g)
		@project_paths.push path if path.directory?
	end
		
	@msgs.push Message.new("danger", "user does have access to any project directories") if @project_paths.empty?

	# look for hw directories in the project directories
	@project_paths.each do | pp |
		Pathname.glob(pp + "*" + IDENTIFICATION_FILE) do | p |
			hw_dir_path = p.dirname	
			@table_rows.push ClassInfo.new(hw_dir_path)
		end
	end

	@table_rows.sort_by!{|c| c.date_created}.reverse!
	
	erb :index
end

get '/all/:project' do
	@table_rows = Array.new
	@project = params[:project]

	@project_path = Pathname.new(PROJECTS_DIR).join(@project)
	halt 404, "File or directory not found" unless @project_path.exist?
	halt 403, "Permission denied" unless @project_path.readable?

	Pathname.glob(@project_path + "*" + IDENTIFICATION_FILE) do | p |
		hw_dir_path = p.dirname
		@table_rows.push ClassInfo.new(hw_dir_path)
	end

	@table_rows.sort_by!{|c| c.date_created}.reverse!

	erb :project
end

get '/all/:project/:class' do
	@table_rows = Array.new # paths to hw submissions (e.g. /fs/project/PZS0530/some_class/osc0001)
	@project = params[:project]
	@class = params[:class]

	class_path = Pathname.new(PROJECTS_DIR).join(@project).join(@class)
	halt 404, "File or directory not found" unless class_path.exist?
	halt 403, "Permission denied" unless class_path.readable?
	halt 401, "Not a homework directory" unless (class_path + IDENTIFICATION_FILE).exist?

	Pathname.glob(class_path + "*" + DATE_FILE) do | p |
		assign_path = p.dirname	
		@table_rows.push AssignmentInfo.new(assign_path)
	end	
	
	@table_rows.sort_by!{|c| c.date_due.nil? ? c.date_created : c.date_due}.reverse!

	erb :class	
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

post '/add/class' do
	msgs = Array.new
	pn = Pathname.new(params[:parent_dir])
	
	halt 404, "Parent directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.writable?
	halt 400, "Not a directory" unless pn.directory?
		
	class_name = params[:class_name]

	redirect_back_with_msg("danger", "Invalid class name: '#{class_name}'") unless class_name.match /\A\w+$\z/
	
	script_pn = Pathname.new(".").realpath.join("hw_dir_setup")

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
	redirect back
end
