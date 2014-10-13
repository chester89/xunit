#please remember to use albacore v1.0.x, because v2 is VERY surprising
require "fileutils"
require "albacore"
require "json"
require "rexml/document"
require "open-uri"
include REXML

SOLUTION_PATH = 'xunit-NoXamarin.sln'
SOLUTION_DIR = 'src'
DEFAULT_CONFIG = 'Release'
PARALLELIZE_TESTS = true
MAX_PARALLEL_THREADS = 0
REQUESTED_VERBOSITY = 'normal'
TRACK_FILE_ACCESS = false

NUGET_PATH = '.nuget/NuGet.exe'
PACKAGE_SOURCES = 'https://nuget.org/api/v2;http://www.myget.org/F/b4ff5f68eccf4f6bbfed74f055f88d8f'

def fileReplace(file_path, old, replacement)
	outdata = File.read(file_path).gsub(old, replacement)

	File.open(file_path, 'w') do |out|
	  out << outdata
	end
end

def regexReplace(file_path)
	outdata = File.read(file_path).gsub /<OutputPath>bin\\(\w+)<\/OutputPath>/, '<OutputPath>bin\\\\\1.x86\\</OutputPath>'

	File.open(file_path, 'w') do |out|
	  out << outdata
	end
end

module Platform
  def self.is_nix
    !RUBY_PLATFORM.match("linux|darwin").nil?
  end

  def self.runtime(cmd)
    command = cmd
    if self.is_nix
      command = "mono #{cmd}"
    end
    command
  end

  def self.switch(arg)
    sw = self.is_nix ? " -" : " /"
    sw + arg
  end
end 

desc "Replaces"
task :replace do
	fileReplace('src/xunit.console/xunit.console.csproj', "<AssemblyName>xunit.console</AssemblyName>", "<AssemblyName>xunit.console.x86</AssemblyName>")	
end

desc "Increments the file and assembly version"
assemblyinfo :version => 'vrsn:build_increment' do |cmd|
	app_details = BuildProcess.app_details
	commit_hash = `git log -1 --format="%H%"`
	
	#cmd.version = cmd.file_version = ?
	puts "set version to #{cmd.version}"
	
	cmd.title = app_details['title']
	cmd.description = commit_hash[0..(commit_hash.length - 3)]
	cmd.company_name = app_details['company']
	cmd.product_name = app_details['product']
	cmd.copyright =  app_details['copyright']
	cmd.output_file = "src/CommonAssemblyInfo.cs"
end

namespace :nuget do
	desc "Downloads NuGet binary"
	task :download do
		unless File.exists?(NUGET_PATH)
			path_parts = NUGET_PATH.split('/')
			dirname = path_parts[0..(path_parts.length - 2)].join('/')
			unless File.directory?(dirname)
			  FileUtils.mkdir_p(dirname)
			end
			puts 'Downloading NuGet binary...'
			File.open(NUGET_PATH, "wb") do |saved_file|
			  open("http://nuget.org/nuget.exe", "rb") do |read_file|
			    saved_file.write(read_file.read)
			  end
			end
			puts 'done'
		else
			puts 'NuGet binary is already in place '
		end
	end

	desc "Downloads missing Nuget packages"
	task :restore do
		commands = [
			"install xunit.buildtasks -Source \"#{PACKAGE_SOURCES}\" -SolutionDirectory #{SOLUTION_DIR} -Verbosity quiet -ExcludeVersion",
			"install githublink -Pre -Source \"#{PACKAGE_SOURCES.split(';')[1]}\" -SolutionDirectory #{SOLUTION_DIR} -Verbosity quiet -ExcludeVersion",
			"restore #{SOLUTION_PATH} -NonInteractive -Source #{PACKAGE_SOURCES} -Verbosity quiet"
		]

		commands.each do |cmd|
			wrapped_command = Platform.runtime("#{NUGET_PATH} " + cmd)
			puts 'Running nuget with ' + wrapped_command
			result = `#{wrapped_command}`
			puts result
		end
	end

	desc "Checks whether all NuGet binaries are in place"
	task :check => :restore do
		puts "Checking if NuGet package binaries are in place..."
		project_files = Rake::FileList['**/*.csproj']
		error_count = 0
		project_files.each do |pf|
			puts "Checking project file #{pf}..."
			File.open(pf) do |f|
				doc = Document.new(f)	  
				packages_paths = XPath.match(doc, "//Reference/HintPath").map{|x| x.text}
				
				packages_paths.each do |pp| 
					up_dir_count = pp.scan("..\\").length
					current = File.dirname(pf)
					up_dir_count.times do
						current = File.expand_path("..", current)
						pp = pp.sub! "..\\", ""
					end
					full_bin_path = File.join(current, pp).gsub!("\\", "/")
					if not File.file?(full_bin_path)
						error_count += 1
						puts "Binary file #{full_bin_path} is missing"
					end
				end
				f.close()
			end
		end
		fail "Not every NuGet package is present, #{error_count} files missing" if error_count > 0
		puts "Done."
	end 

	task :all => [:download, :restore, :check]
end

namespace :build do
	desc "Prepares for build"
	task :prepare do 
		puts 'Preparing to build...'
		project_name = 'xunit.console'
		config_section_name = 'Xunit.ConsoleClient.XunitConsoleConfigurationSection'
		source_project_file = File.join(Dir.pwd, "src/#{project_name}/#{project_name}.csproj")
		target_project_file = source_project_file.sub('.csproj', '.x86.csproj')

		FileUtils.cp(source_project_file, target_project_file)
		fileReplace(target_project_file, "<AssemblyName>#{project_name}</AssemblyName>", "<AssemblyName>#{project_name}.x86</AssemblyName>")
		regexReplace(target_project_file)
		puts 'Prepared fine.'
	end

	task :cleanup do
		puts 'Cleaning up after build...'
		fileReplace("src/#{project_name}/bin/#{DEFAULT_CONFIG}.x86/#{project_name}.x86.exe.config",  
			"#{config_section_name}, #{project_name}",
        	"#{config_section_name}, #{project_name}.x86")
    	FileUtils.rm("src/#{project_name}/#{project_name}.x86.csproj")
    	puts 'Clean up fine.'
	end

	task :ms_full => ['nuget:all', :prepare, :ms, :test_project, :cleanup] do
		puts "Finished building"
	end

	desc "Builds solution with MSBuild"
	msbuild :ms, [:config] => ['nuget:all', :prepare] do |build, args|
		build.solution = SOLUTION_PATH
		build.targets = [:Build]
		build.properties = {
			:Configuration => DEFAULT_CONFIG, 
			:TrackFileAccess => TRACK_FILE_ACCESS
		}
		build.verbosity = :minimal
	end

	desc "Build test project with MSBuild"
	msbuild :test_project, [:config] => ['nuget:all', :prepare] do |build, args|
		build.solution = 'src/xunit.console/xunit.console.x86.csproj'
		build.targets = [:Build]
		build.properties = {
			:PlatformTarget => :x86,
			:Configuration => args.config, 
			:TrackFileAccess => TRACK_FILE_ACCESS
		}
		build.verbosity = :minimal
	end

	desc "Builds solution under Mono environment"
	exec :mono, [:config] => ['nuget:all', :prepare] do |cmd, args|
		cmd.working_directory = Dir.pwd
		cmd.command = "xbuild"
		cmd.parameters = [SOLUTION_PATH, "/p:Configuration=#{args.config}", "/target:Build"]
	end
	
	desc "Switches build logic between environments"
	task :choose, [:config] do |t, args|
		args.with_defaults(:config => DEFAULT_CONFIG)
		task_name = 'build:'
		if(Platform.is_nix)
			task_name += 'mono'
		else
			task_name += 'ms_full'
		end
		Rake::Task[task_name].reenable
		Rake::Task[task_name].invoke(args.config)
	end
end

namespace :tests do
	desc "Runs unit tests"
	xunit :unit => 'build:choose' do |xu, args|
		args.with_defaults(:config => DEFAULT_CONFIG)
		project_name = "CurrencyRates.Services.UnitTests"
		report_dir = "XUnitResults"
		xu.command = "tools/xunit/xunit.console.clr4.exe"
		xu.assembly = "src/#{project_name}/bin/#{args[:config]}/#{project_name}.dll"
		Dir.mkdir(report_dir) unless File.exists?(report_dir)
		xu.html_output = report_dir
	end
end

desc "Packages the app"
zip :pack do |cmd|
	app_details = BuildProcess.app_details
	out_dir = "artifacts"
	short_commit_hash = `git log --pretty=format:'%h' -n 1`
	pure_hash = short_commit_hash[1..(short_commit_hash.length - 2)]
	cmd.directories_to_zip = ["src/Scheduler/bin/Release/"]
	cmd.additional_files = [VERSION_FILE_NAME]
	Dir.mkdir(out_dir) unless File.exists?(out_dir)
	cmd.output_file = "../../../../#{out_dir}/#{app_details['product']}-#{BuildProcess.full_version_number}-#{pure_hash}.zip"
	cmd.flatten_zip
	cmd.exclusions = [/\.xml$/, /\.pdb$/, /\.nlp$/]
end

task :default => ['build:choose']