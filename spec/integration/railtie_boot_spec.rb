# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# Boots a minimal Rails app in a child process - loading Rails into this
# process would flip `defined?(::Rails)` for every other spec. Proves the three
# things the Railtie exists for: Zeitwerk ignores the eval/ dirs (an eval file
# defines no constant; unignored, eager loading requires it a second time and
# expects Eval::ClassifyTicketEval), evals are registered after boot, and the
# rake tasks appear without a require in the app's Rakefile.
RSpec.describe "Railtie in a booted Rails app" do
  let(:boot_script) do
    <<~RUBY
      require "logger"
      require "rails"
      require "ruby_llm/contract"

      class RailtieProbeApp < Rails::Application
        config.root = Dir.pwd
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "railtie-probe"
      end
      Rails.application.initialize!
      # Read before anything else touches the autoloaders: registration must
      # happen during boot, not as a side effect of eager loading below.
      eval_names_after_boot = { contracts: ClassifyTicket.eval_names, steps: RouteTicket.eval_names }

      eval_file = File.join(Dir.pwd, "app/contracts/eval/classify_ticket_eval.rb")
      eval_file_cpath = Rails.autoloaders.main.cpath_expected_at(eval_file)

      eager_load_error = begin
        Rails.application.eager_load!
        nil
      rescue StandardError => e
        "\#{e.class}: \#{e.message}"
      end

      Rails.application.load_tasks
      optimize = Rake::Task.task_defined?("ruby_llm_contract:optimize") && Rake::Task["ruby_llm_contract:optimize"]

      puts JSON.generate(
        railtie: defined?(RubyLLM::Contract::Railtie) ? true : false,
        eager_load_error: eager_load_error,
        eval_file_cpath: eval_file_cpath,
        eval_file_required_by_zeitwerk: $LOADED_FEATURES.include?(eval_file),
        eval_names_after_boot: eval_names_after_boot,
        optimize_task: optimize ? true : false,
        optimize_prerequisites: optimize ? optimize.prerequisites : []
      )
    RUBY
  end

  # One step class per Rails contract dir, each with an eval file under eval/.
  def app_files
    {
      "app/contracts/classify_ticket.rb" =>
        %(class ClassifyTicket < RubyLLM::Contract::Step::Base\n  prompt "Classify: {input}"\nend\n),
      "app/contracts/eval/classify_ticket_eval.rb" =>
        %(ClassifyTicket.define_eval("smoke") { default_input "refund"; sample_response({ priority: "high" }) }\n),
      "app/steps/route_ticket.rb" =>
        %(class RouteTicket < RubyLLM::Contract::Step::Base\n  prompt "Route: {input}"\nend\n),
      "app/steps/eval/route_ticket_eval.rb" =>
        %(RouteTicket.define_eval("routing") { default_input "refund"; sample_response({ team: "billing" }) }\n)
    }
  end

  def boot(dir)
    app_files.merge("boot.rb" => boot_script).each do |path, source|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), source)
    end

    lib = File.expand_path("../../lib", __dir__)
    Open3.capture3(RbConfig.ruby, "-I", lib, "boot.rb", chdir: dir)
  end

  it "ignores eval dirs for Zeitwerk, registers evals, and adds the rake tasks" do
    stdout, stderr, status = Dir.mktmpdir { |dir| boot(dir) }

    expect(status).to be_success, "child process failed:\n#{stderr}"
    report = JSON.parse(stdout.lines.last, symbolize_names: true)

    expect(report).to include(railtie: true, eager_load_error: nil, eval_file_cpath: nil,
                              eval_file_required_by_zeitwerk: false, optimize_task: true,
                              eval_names_after_boot: { contracts: ["smoke"], steps: ["routing"] })
    expect(report[:optimize_prerequisites]).to eq(["environment"])
  end
end
