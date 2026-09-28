# frozen_string_literal: true

module Raxon
  # Development-mode route hot reloading.
  #
  # Watches the configured routes directories (route files and their .erb
  # templates) plus the helpers_path, and when any watched file is added,
  # removed, or modified, reloads all routes and helpers before the request is
  # routed. The Router creates one when Raxon.configuration.reload_routes? is
  # true (default: development environment only).
  #
  # The reload is a full rebuild: every route file is re-evaluated, so route
  # files must stay self-contained (which the isolated per-file class context
  # already encourages). State registered programmatically at boot survives —
  # the catchall endpoint is preserved, and OpenAPI components, security
  # schemes, and configuration blocks live outside the route registry.
  #
  # The rebuild is published atomically (see {RouteLoader.reload!}), which
  # matters because requests keep arriving during it. A concurrent request
  # sees either the complete previous route table or the complete new one,
  # never a partial build, and an error in a changed file leaves the previous
  # table serving instead of taking every route down with it. The error still
  # surfaces on the request that triggered the reload; fixing the file
  # triggers another reload and recovers.
  class RouteReloader
    def initialize
      @mutex = Mutex.new
      @snapshot = current_snapshot
    end

    # Reload routes when any watched file changed since the last snapshot.
    #
    # The snapshot globs and stats every watched file, about 7ms for 680
    # files. Taking it inside the lock made every concurrent request wait for
    # every other request's scan. It is taken before the lock, and the lock
    # is taken only when something changed. Inside the lock the comparison
    # runs again, so when several requests see one change, one of them
    # reloads and the rest do not.
    #
    # Every request still checks, so an edit is never served stale. The
    # snapshot is taken before the reload reads the files, so an edit that
    # lands during a reload is either read by it or seen by the next request.
    #
    # @return [void]
    def reload_if_changed
      snapshot = current_snapshot
      return if snapshot == @snapshot

      @mutex.synchronize do
        next if snapshot == @snapshot

        @snapshot = snapshot
        reload!
      end
    end

    private

    def reload!
      # The catchall is registered programmatically at boot (config.ru); a
      # file reload cannot recreate it, so carry it across the rebuild.
      catchall = RouteLoader.catchall

      # Route files register endpoint specs with the OpenAPI DSL as they
      # load; drop the previous generation so the generated document does not
      # accumulate duplicate operations. Boot-registered endpoints without a
      # route file are kept.
      OpenApi::DSL.default_spec.drop_route_file_endpoints!

      # Rebuilds from disk and swaps the registry in atomically, so a request
      # in flight never sees a partially loaded route table.
      RouteLoader.reload!
      RouteLoader.catchall = catchall if catchall

      Raxon.reload_helpers
    end

    def current_snapshot
      watched_files.each_with_object({}) do |file, snapshot|
        snapshot[file] = File.mtime(file).to_f
      rescue Errno::ENOENT
        # Deleted between glob and stat; treat as absent.
      end
    end

    def watched_files
      watched_directories.flat_map do |directory|
        Dir.glob(File.join(directory, "**", "*.{rb,erb}"))
      end.sort
    end

    def watched_directories
      directories = Array(Raxon.configuration.routes_directory).compact
      helpers_path = Raxon.configuration.helpers_path
      directories += [helpers_path] if helpers_path
      directories.map { |directory| File.expand_path(directory) }.uniq
    end
  end
end
