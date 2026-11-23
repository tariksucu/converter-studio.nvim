NVIM ?= nvim
MINI_TEST ?= deps/mini.test
MINI_TEST_VERSION ?= v0.18.0
# The tests write their caches and state here (removed afterwards), not in your Neovim folders.
TEST_HOME := $(CURDIR)/.tests

.PHONY: test lint format deps clean

test: $(MINI_TEST)
	XDG_CONFIG_HOME=$(TEST_HOME)/config XDG_DATA_HOME=$(TEST_HOME)/data \
	XDG_STATE_HOME=$(TEST_HOME)/state XDG_CACHE_HOME=$(TEST_HOME)/cache \
	MINI_TEST=$(abspath $(MINI_TEST)) \
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"; \
	status=$$?; rm -rf $(TEST_HOME); exit $$status

lint:
	stylua --check lua plugin tests
	luacheck lua plugin tests

format:
	stylua lua plugin tests

deps: $(MINI_TEST)

$(MINI_TEST):
	git clone --quiet --depth 1 --branch $(MINI_TEST_VERSION) https://github.com/nvim-mini/mini.test $@

clean:
	rm -rf .tests deps
