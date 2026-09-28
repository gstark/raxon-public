# frozen_string_literal: true

module Raxon
  # Guards against loading files that escape a trusted directory tree through a
  # symlink.
  #
  # +File.expand_path+ collapses ".." lexically but does not follow symlinks, so
  # a symlink placed inside a routes or helpers tree could point at a file
  # elsewhere on disk and be loaded — executing arbitrary code with full process
  # privileges. This resolves the real (symlink-followed) path and confirms it
  # stays within one of the trusted roots, letting in-tree symlinks through
  # while rejecting escaping ones.
  #
  # This is defense in depth, not a sandbox: route and helper files are trusted,
  # developer-authored code and always run with full privileges. Keep those
  # directories owned by the deployment and not writable by untrusted users.
  module PathContainment
    module_function

    # Resolve trusted root directories to their real (symlink-followed) paths.
    # Roots that do not exist are dropped.
    #
    # @param dirs [Array<String>]
    # @return [Array<String>] existing roots as real paths
    def resolve_roots(dirs)
      dirs.filter_map do |dir|
        File.realpath(dir)
      rescue SystemCallError
        nil
      end
    end

    # Whether +file+'s real path is one of +roots+ or a descendant of one.
    # +roots+ must already be real paths (see {resolve_roots}). A file that
    # cannot be resolved (a broken or looping symlink) is treated as not
    # contained.
    #
    # @param file [String]
    # @param roots [Array<String>] real paths of the trusted roots
    # @return [Boolean]
    def contained?(file, roots)
      real = File.realpath(file)
      roots.any? { |root| real == root || real.start_with?(root + File::SEPARATOR) }
    rescue SystemCallError
      false
    end
  end
end
