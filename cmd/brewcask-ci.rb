# frozen_string_literal: false

require "utils/github"
require "utils/formatter"

require_relative "lib/capture"
require_relative "lib/check"
require_relative "lib/travis"

module Cask
  class Cmd
    class Ci < AbstractCommand
      def self.escape(string)
        string.gsub(/\r/, "%0D")
              .gsub(/\n/, "%0A")
              .gsub(/]/, "%5D")
              .gsub(/;/, "%3B")
      end

      def run
        raise CaskError, "This command isn’t meant to be run locally." unless ENV.key?("CI")

        $stdout.sync = true
        $stderr.sync = true

        raise CaskError, "This command must be run from inside a tap directory." unless tap

        @commit_range = begin
          commit_range_start = system_command!("git", args: ["rev-parse", "origin/master"]).stdout.chomp
          commit_range_end = system_command!("git", args: ["rev-parse", "HEAD"]).stdout.chomp
          "#{commit_range_start}...#{commit_range_end}"
        end

        ruby_files_in_wrong_directory =
          modified_ruby_files - (modified_cask_files + modified_command_files + modified_github_files)

        unless ruby_files_in_wrong_directory.empty?
          raise CaskError, "Casks are in the wrong directory:\n" +
                           ruby_files_in_wrong_directory.join("\n")
        end

        if modified_cask_files.count > 1 && tap.name != "homebrew/cask-fonts"
          raise CaskError, "More than one cask modified; please submit a pull request for each cask separately."
        end

        overall_success = true

        modified_cask_files.each do |path|
          cask = CaskLoader.load(path)

          overall_success &= step "brew cask style #{cask.token}", "style" do
            Style.run(path)
            true
          rescue
            json = Style.rubocop(path, json: true)

            json.fetch("files").each do |file|
              file.fetch("offenses").each do |o|
                path = Pathname(file.fetch("path")).relative_path_from(tap.path).to_s
                line = o.fetch("location").fetch("start_line")
                column = o.fetch("location").fetch("start_column")
                message = o.fetch("message")
                puts "::error file=#{self.class.escape(path)},line=#{line},col=#{column}" \
                     "::#{self.class.escape(message)}"
              end
            end

            false
          end

          overall_success &= step "brew cask audit #{cask.token}", "audit" do
            Auditor.audit(cask, audit_download:        true,
                                audit_appcast:         true,
                                audit_token_conflicts: added_cask_files.include?(path),
                                commit_range:          @commit_range)
          end

          if (macos_requirement = cask.depends_on.macos) && !macos_requirement.satisfied?
            opoo "Skipping installation: #{macos_requirement.message}"
            next
          end

          was_installed = cask.installed?

          installer = Installer.new(cask, verbose: true)

          cask_and_formula_dependencies = installer.missing_cask_and_formula_dependencies

          check = Check.new

          overall_success &= step "brew cask install #{cask.token}", "install" do
            if was_installed
              old_cask = CaskLoader.load(cask.installed_caskfile)
              Installer.new(old_cask, verbose: true).zap
            end

            check.before

            installer.install
          end

          overall_success &= step "brew cask uninstall #{cask.token}", "uninstall" do
            success = begin
              if manual_installer?(cask)
                puts "Cask has a manual installer, skipping..."
              else
                installer.uninstall
              end
              true
            rescue => e
              $stderr.puts e.message
              $stderr.puts e.backtrace
              false
            ensure
              cask_and_formula_dependencies.reverse_each do |cask_or_formula|
                next unless cask_or_formula.is_a?(Cask)

                Installer.new(cask_or_formula, verbose: true).uninstall if cask_or_formula.installed?
              end
            end

            check.after

            next success if check.success?

            $stderr.puts check.message
            false
          end

          next unless check.success? && !check.success?(ignore_exceptions: false)

          overall_success &= step "brew cask zap #{cask.token}", "zap" do
            success = begin
              Installer.new(cask, verbose: true).zap
              true
            rescue => e
              $stderr.puts e.message
              $stderr.puts e.backtrace
              false
            end

            check.after

            next success if check.success?(ignore_exceptions: false)

            $stderr.puts check.message(stanza: "zap")
            false
          end
        end

        if overall_success
          puts Formatter.success("Build finished successfully.", label: "Success")
          return
        end

        raise CaskError, "Build failed."
      end

      private

      def step(name, travis_id)
        unless ENV.key?("TRAVIS_COMMIT_RANGE")
          puts Formatter.headline(name, color: :yellow)
          return yield != false
        end

        success = false
        output = nil

        Travis.fold travis_id do
          print Formatter.headline("#{name} ", color: :yellow)

          real_stdout = $stdout.dup

          travis_wait = Thread.new do
            loop do
              sleep 595
              real_stdout.print "\u200b"
            end
          end

          success, output = capture do
            yield != false
          rescue => e
            $stderr.puts e.message
            $stderr.puts e.backtrace
            false
          end

          travis_wait.kill
          travis_wait.join

          if success
            puts Formatter.success("✔")
            puts output unless output.empty?
          else
            puts Formatter.error("✘")
          end
        end

        puts output unless success

        success
      end

      def tap
        @tap ||= Tap.from_path(Dir.pwd)
      end

      def modified_files
        @modified_files ||= system_command!(
          "git", args: ["diff", "--name-only", "--diff-filter=AMR", @commit_range]
        ).stdout.split("\n").map { |path| Pathname(path) }
      end

      def added_files
        @added_files ||= system_command!(
          "git", args: ["diff", "--name-only", "--diff-filter=A", @commit_range]
        ).stdout.split("\n").map { |path| Pathname(path) }
      end

      def modified_ruby_files
        @modified_ruby_files ||= modified_files.select { |path| path.extname == ".rb" }
      end

      def modified_command_files
        @modified_command_files ||= modified_files.select { |path| path.ascend.to_a.last.to_s == "cmd" }
      end

      def modified_github_files
        @modified_github_files ||= modified_files.select { |path| path.to_s.start_with?(".github/") }
      end

      def modified_cask_files
        @modified_cask_files ||= modified_files.select { |path| tap.cask_file?(path) }
      end

      def added_cask_files
        @added_cask_files ||= added_files.select { |path| tap.cask_file?(path) }
      end

      def manual_installer?(cask)
        cask.artifacts.any? { |artifact| artifact.is_a?(Artifact::Installer::ManualInstaller) }
      end
    end
  end
end
