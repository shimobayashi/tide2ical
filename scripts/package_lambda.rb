require 'fileutils'
require 'rbconfig'

abort 'Lambda と同じ Ruby 3.4 で実行してください' unless RUBY_VERSION.start_with?('3.4.')

root = File.expand_path('..', __dir__)
package = File.join(root, 'build/package')
FileUtils.rm_rf(package)
FileUtils.mkdir_p(package)
%w[Gemfile Gemfile.lock lambda_function.rb lib].each do |path|
  FileUtils.cp_r(File.join(root, path), package)
end
FileUtils.mkdir_p(File.join(package, '.bundle'))
File.write(File.join(package, '.bundle/config'), "BUNDLE_PATH: vendor/bundle\nBUNDLE_WITHOUT: test\n")

env = {
  'BUNDLE_GEMFILE' => File.join(package, 'Gemfile'),
  'BUNDLE_PATH' => File.join(package, 'vendor/bundle'),
  'BUNDLE_WITHOUT' => 'test',
  'BUNDLE_FROZEN' => 'true'
}
success = system(env, RbConfig.ruby, '-S', 'bundle', 'install', chdir: package)
abort '依存ライブラリの準備に失敗しました' unless success

puts "Lambda の配布用ディレクトリを作成しました: #{package}"
