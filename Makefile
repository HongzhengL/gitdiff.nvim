.PHONY: test clean

test:
	nvim --headless -i NONE -n -u scripts/test_init.lua -c \
		"PlenaryBustedDirectory tests/ { minimal_init = './scripts/test_init.lua' }"

clean:
	rm -rf .tests
