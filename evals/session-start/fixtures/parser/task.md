parse_date() in src/parse.py ignores the timezone offset in the timestamp. Fix it so the result is the correct UTC time (src/util.py has the helper that splits the stamp). Run sh test.sh when done.
