project('disruptor', 'd',
    license: ['LGPL-3.0-or-later', 'MPL-2.0'],
    meson_version: '>=0.54.0',
    version: '0.1.0'
)

disruptor_lib = library(
    'disruptor',
    ['source/disruptor.d'],
    build_by_default: false,
    include_directories: 'source'
)

disruptor_dep = declare_dependency(
    include_directories: 'source',
    link_with: disruptor_lib
)

meson.override_dependency(meson.project_name(), disruptor_dep)

disruptor_test_exe = executable(
    'disruptor-test',
    ['source/disruptor.d', 'tests/main.d'],
    include_directories: 'source',
    d_unittest: true
)

test('disruptor', disruptor_test_exe)