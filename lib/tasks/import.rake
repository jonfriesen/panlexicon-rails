require 'pathname'

namespace :import do
  desc "Import comma-separated values from Moby Thesaurus"
  task :moby, [:file_path] => :environment do |t, args|
    args.with_defaults :file_path => 'moby_thesaurus.txt'

    filepath = Pathname(args[:file_path])
    if filepath.exist?
      importer = MobyImporter.new(filepath)
      importer.import
    else
      abort "Cannot find file: #{filepath.realpath}"
    end
  end
end