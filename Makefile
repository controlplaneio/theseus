.PHONY : test test-acceptance test-unit
.SILENT:

test :
	cd test && ./test-acceptance.sh && ./test-theseus.sh

test-acceptance :
	cd test && ./test-acceptance.sh

test-unit :
	cd test && ./test-theseus.sh
