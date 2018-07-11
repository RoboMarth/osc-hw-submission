require 'sinatra'
require 'open3'
require 'pathname'

get '/download/*' do | glob |
	pn = Pathname.new("/fs/project/#{glob}")
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
		"Not a file or directory"
	end
end	

# TODO: use better route name and redirect back with session containing errors
post '/' do
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
	
	redirect to '/'
end

get '/' do
	@errors = Array.new # store any errors that occur
	@dir_paths = Array.new # store paths to found homework directories

	# get user
	stdout_str, stderr_str, status = Open3.capture3("whoami")
	@errors.push "could not establish identity (whoami)" unless status.success?
	@user = stdout_str.chomp

	# get groups
	stdout_str, stderr_str, status = Open3.capture3("groups")
	@errors.push "could not identify user's groups (groups)" unless status.success?
	groups = stdout_str.chomp.split
	
	# look for project directories under /fs/project/
	@project_paths = Array.new
	groups.each do | g |
		path = Pathname.new("/fs/project").join(g)
		@project_paths.push path if path.directory?
	end
		
	@errors.push "user does have access to any project directories" if @project_paths.empty?

	# look for hw directories in the project directories
	@project_paths.each do | p |
		Pathname.glob(p + "*" + "this_is_a_homework_directory") do | p2 |
			@dir_paths.push p2.dirname if p2.file?
		end
	end

	@dir_paths = @dir_paths.sort_by{|p| (p + "this_is_a_homework_directory").mtime}.reverse!
	
	if @errors.empty?
		erb :index
	else
		@errors
	end
end

get '/:project' do
	@dir_paths = Array.new
	@project = params[:project]

	pn = Pathname.new("/fs/project/#{@project}")
	halt 404, "File or directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.readable?

	Pathname.glob(pn + "*" + "this_is_a_homework_directory") do | p |
		@dir_paths.push p.dirname
	end

	@dir_paths = @dir_paths.sort_by{|p| (p + "this_is_a_homework_directory").mtime}.reverse!

	erb :project
end

get '/:project/:class' do
	@dir_paths = Array.new # paths to hw submissions (e.g. /fs/project/PZS0530/some_class/osc0001)
	@project = params[:project]
	@class = params[:class]

	pn = Pathname.new("/fs/project/#{@project}/#{@class}")
	halt 404, "File or directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.readable?
	halt 401, "Not a homework directory" unless (pn + "this_is_a_homework_directory").exist?

	erb :class	
end
