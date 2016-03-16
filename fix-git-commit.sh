#!/bin/sh

set -ev

git --version

BAD_COMMIT=509591f78f37905913ba0cbd832e5e4f7b925a8a

git cat-file -p $BAD_COMMIT

git remote remove origin

git tag -l | xargs git tag -d

git filter-branch \
	--commit-filter \
		'if [ $GIT_COMMIT = 509591f78f37905913ba0cbd832e5e4f7b925a8a ]; then
			export GIT_AUTHOR_NAME="Cédric Luthi"
			export GIT_AUTHOR_EMAIL="cedric.luthi@gmail.com"
			export GIT_AUTHOR_DATE="Fri Jul 30 11:20:46 2010 +0200"
			export GIT_COMMITTER_NAME="PreEmptive Solutions"
			export GIT_COMMITTER_EMAIL="support@preemptive.com"
			export GIT_COMMITTER_DATE="Fri Jul 30 11:20:46 2010 +0200"
			git commit-tree "$@" | tee /tmp/fixit.log
		else
			git commit-tree "$@"
		fi' \
	-- --all

NEW_COMMIT=`cat /tmp/fixit.log`

git update-ref -d refs/original/refs/heads/master

git reflog expire --expire=now --all

git gc --prune=now

git fsck

git cat-file -p $BAD_COMMIT || true

git cat-file -p $NEW_COMMIT

export GIT_COMMITTER_NAME="PreEmptive Solutions"
export GIT_COMMITTER_EMAIL="support@preemptive.com"
git tag -a -m "The details (name/email/date) of this commit were corrupt in the
upstream fork (according to git fsck). We fixed it via filter-branch,
rewriting subsequent history. The original commit ID (for this commit)
was ${BAD_COMMIT}." 'fix-corrupt-commit' $NEW_COMMIT

git cat-file -p fix-corrupt-commit

echo "Done!"

