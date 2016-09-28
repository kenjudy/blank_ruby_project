# blank ruby project
Base implementation of ruby project using minitest

# subreddit
#  submissions 10000 (subreddit.get_new)
#     submission -> authors
#  submission -> comments 10000 (submission.comments)
#      comment -> authors

# author (bot.client.user_from_name)
#   submissions (get_submitted)
#      submission -> subreddit
#   comments (get_comments)
#       comment -> subreddit

#subreddit_to_subreddit (count)
#[
#  {
#    subredit: name,
#    occurences: number
#  }
#]
#sort by number
