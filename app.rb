require 'sinatra'
require 'open3'
require 'pathname'

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
	project_paths = Array.new
	groups.each do | g |
		path = Pathname.new("/fs/project").join(g)
		project_paths.push path if path.directory?
	end
		
	@errors.push "user does have access to any project directories" if project_paths.empty?

	# look for hw directories in the project directories
	project_paths.each do | p |
		Pathname.glob(p + "*" + "this_is_a_homework_directory") do | p2 |
			@dir_paths.push p2.dirname
		end
	end
	
	if @errors.empty?
		erb :index
	else
		@errors
	end
end

get '/:project' do | project |
	@dir_paths = Array.new
	@project = project

	pn = Pathname.new("/fs/project/#{project}")
	halt 404, "File or directory not found" unless pn.exist?
	halt 403, "Permission denied" unless pn.readable?

	Pathname.glob(pn + "*" + "this_is_a_homework_directory") do | p |
		@dir_paths.push p.dirname
	end

	erb :project
end

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

