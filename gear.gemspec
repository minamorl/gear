# frozen_string_literal: true

require_relative 'lib/gear/version'

Gem::Specification.new do |spec|
  spec.name = 'gear'
  spec.version = Gear::VERSION
  spec.summary = 'An execution machine: tick, admission, receipt, journal.'
  spec.description = <<~DESC
    gear runs programs so that they can be connected freely. Programs are
    berylx Task compositions lowered onto darkcore's single Effect type;
    every external access goes through a port adapter, every side effect
    passes admission first and emits a receipt, and the journal is the sole
    source of truth from which state is folded and UIs are rendered.
  DESC
  spec.authors = ['minamorl']
  spec.email = ['minamorl@users.noreply.github.com']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/minamorl/gear'

  spec.required_ruby_version = '>= 3.2'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir['lib/**/*.rb', 'README.md', 'LICENSE', 'AGENTS.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'berylx'
  spec.add_dependency 'darkcore'
  spec.add_dependency 'zeolite'
end
