require 'sinatra'
require 'open3'
require 'pathname'
require 'etc'

enable :sessions

IDENTIFICATION_FILE = "this_is_a_homework_directory" # file found in HW directories to identify them as such
PROJECTS_DIR = "/fs/project/" # directory contataining all project folders

ClassInfo = Struct.new(:name, :project, :instructor, :assignments, :submissions, :date_created) do
	def initialize (hw_dir_path)
		self[:name] = hw_dir_path.basename.to_s
		self[:project] = hw_dir_path.dirname.basename.to_s
		self[:instructor] = Etc.getpwuid(hw_dir_path.stat.uid).name
		self[:assignments] = hw_dir_path.children.count - 2 # minus 2 because of scripts directory and homework dir file 
		self[:submissions] = hw_dir_path.children.flat_map {|pc| pc.children if pc.directory?}.compact.count{|x| x.directory?} 
		self[:date_created] = (hw_dir_path + IDENTIFICATION_FILE).mtime
	end
end

AssignmentInfo = Struct.new(:name, :submissions, :date_due)

Message = Struct.new(:type, :text) # type corresponds to bootstrap theme colors: success, danger, warning, info

helpers do
	def redirect_back_with_msgs(messages)
		session[:msgs] = messages
		redirect back	
	end
end

get '/' do
	redirect to '/all'
end

get '/all' do
	@table_rows = Array.new # store ClassInfo objects
	@msgs = session[:msgs] # store any Messages that need to be displayed (i.e errors)
	@project_paths = Array.new

	# get groups
	stdout_str, stderr_str, status = Open3.capture3("groups")
	@msg.push Message.new("danger", "could not identify user's groups (groups)") unless status.success?
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

	@table_rows = @table_rows.sort_by{|c| c.date_created}.reverse!
	
	erb :index
end

get '/all/:project' do
	@table_rows = Array.new
	@project = params[:project]

	pn = Pathname.new(PROJECTS_DIR).join(@project)
	halt 404, "File or directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.readable?

	Pathname.glob(pn + "*" + IDENTIFICATION_FILE) do | p |
		hw_dir_path = p.dirname
		@table_rows.push ClassInfo.new(hw_dir_path)
	end

	@table_rows = @table_rows.sort_by{|c| c.date_created}.reverse!

	erb :project
end

get '/all/:project/:class' do
	@dir_paths = Array.new # paths to hw submissions (e.g. /fs/project/PZS0530/some_class/osc0001)
	@project = params[:project]
	@class = params[:class]

	pn = Pathname.new(PROJECTS_DIR).join(@project).join(@class)
	halt 404, "File or directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.readable?
	halt 401, "Not a homework directory" unless (pn + IDENTIFICATION_FILE).exist?

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
	pn = Pathname.new(params[:parent_dir])
	
	halt 404, "Parent directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.writable?
	halt 400, "Not a directory" unless pn.directory?
		
	class_name = params[:class_name]
	
	halt 400, "Invalid class name" unless class_name.match /\A\w+$\z/
	
	script_pn = Pathname.new("./hw_dir_setup").realpath

	halt 500, "Could not access internal script" unless script_pn.executable? 	

	hw_dir_setup_cmd = "#{script_pn} #{class_name} #{pn.basename}"	

	# create new hw directory under project
	Dir.chdir(pn.to_s) do
		stdout, stderr, status = Open3.capture3(hw_dir_setup_cmd)
		halt 500, "could not create hw directory: #{stdout}" unless status.success?		
	end
	
	redirect back
end

post '/add/assignment' do
	redirect back
end
