#!/bin/sh

# Copyright (c) 2006 Karl Hasselström

test_description='Test the repair command'

. ./test-lib.sh

test_expect_success 'Repair in a non-initialized repository' '
    command_error stg repair 2>err &&
    grep -e "StGit stack not initialized for branch \`master\`" err
'

test_expect_success 'Initialize the StGit repository' '
    stg init
'

test_expect_success 'Repair in a repository without patches' '
    stg repair
'

test_expect_success 'Repair with invalid arguments' '
    general_error stg repair xxx 2>err &&
    grep -e "unexpected argument .xxx." err
'

test_expect_success 'Create a patch' '
    stg new foo -m foo &&
    echo foo >foo.txt &&
    stg add foo.txt &&
    stg refresh
'

test_expect_success 'Attempt repair of protected branch' '
    test_when_finished "stg branch --unprotect" &&
    stg branch --protect &&
    command_error stg repair 2>err &&
    grep -e "this branch is protected" err
'

test_expect_success 'Repair when there is nothing to do' '
    stg repair
'

test_expect_success 'Create a Git commit' '
    echo bar >bar.txt &&
    git add bar.txt &&
    git commit -a -m bar
'

test_expect_success 'Turn one Git commit into a patch' '
    [ "$(echo $(stg series --applied --noprefix))" = "foo" ]
    stg repair &&
    [ "$(echo $(stg series --applied --noprefix))" = "foo bar" ]
    [ $(stg series --unapplied -c) -eq 0 ]
'

test_expect_success 'Create three more Git commits' '
    echo one >numbers.txt &&
    git add numbers.txt &&
    git commit -a -m one &&
    echo two >>numbers.txt &&
    git commit -a -m two &&
    echo three >>numbers.txt &&
    git commit -a -m three
'

test_expect_success 'Turn three Git commits into patches' '
    [ "$(echo $(stg series --applied --noprefix))" = "foo bar" ]
    stg repair &&
    [ "$(echo $(stg series --applied --noprefix))" = "foo bar one two three" ]
    [ $(stg series --unapplied -c) -eq 0 ]
'

test_expect_success 'Create a merge commit' '
    git config pull.rebase false &&
    git checkout -b br master^^ &&
    echo woof >woof.txt &&
    stg add woof.txt &&
    git commit -a -m woof &&
    git checkout master &&
    git pull . br
'

test_expect_success 'Repair in the presence of a merge commit' '
    [ "$(echo $(stg series --applied --noprefix))" = "foo bar one two three" ]
    stg repair &&
    [ "$(echo $(stg series --unapplied --noprefix))" = "foo bar one two three" ]
    [ $(stg series --applied -c) -eq 0 ]
'

test_done
