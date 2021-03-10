project('disruptor', 'd',
    license: ['LGPL-3.0-or-later', 'MPL-2.0'],
    meson_version: '>=0.54.0',
    version: '0.1.0'
)

disruptor_lib = library(
    'disruptor',
    ['disruptor.d'],
    build_by_default: false,
    include_directories: '..'
)

disruptor_source_dep = declare_dependency(
    include_directories: '../',
    version: meson.project_version()
)

meson.override_dependency(meson.project_name(), disruptor_source_dep)

disruptor_test_exe = executable(
    'disruptor-test',
    ['tests/main.d', 'disruptor.d'],
    dependencies: disruptor_source_dep,
    d_args: ['-i'],
    d_unittest: true
)
