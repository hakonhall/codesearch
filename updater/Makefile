all: test

test: config github update-manifest

config:
	tests/run tests/config_test

github:
	tests/run tests/github_test

update-manifest:
	tests/run tests/update-manifest_test
