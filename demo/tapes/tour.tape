# A first look: the installation, a connections file reviewed and trusted, then the terminal UI on a Kafka cluster.
Output demo/assets/kurkik-demo.gif
Source demo/tapes/setup.tape

# From nothing: no trust yet. Somebody reading orders.created on prod, so a consumer group has a member.
Hide
Type "rm -rf .state && (./reader.sh &) && clear"
Enter
Sleep 1s
Show

# What this installation can reach.
Type "kurkik doctor"
Enter
Sleep 5s

# The connections the project file names: not used until somebody has said so.
Hide
Type "clear"
Enter
Show
Type "kurkik conn ls"
Enter
Sleep 4s

# Reviewed and trusted, then listed again.
Type "kurkik trust"
Enter
Sleep 4s
Type "y"
Enter
Sleep 2s
Type "kurkik conn ls"
Enter
Sleep 4s

# The terminal UI: prod previewed - whether it answers and the overview first.
Hide
Type "clear"
Enter
Show
Type "kurkik"
Enter
Sleep 3s
Down
Sleep 800ms
Enter
Sleep 5s
# Its topics, and all of one: every setting and where it comes from.
Tab
Sleep 3s
Down
Enter
Sleep 3s
Down@300ms 8
Sleep 2s
Escape
Sleep 1s
# The brokers.
Tab
Sleep 3s
# The consumer groups: the one being read has a member.
Tab
Sleep 3s
Enter
Sleep 3s
Escape
Sleep 1s
# Who may do what.
Tab
Sleep 3s
# The registry's subjects, and a schema whole.
Tab
Sleep 3s
Down@400ms 3
Enter
Sleep 4s
Escape
Sleep 1s
Escape
Sleep 1s
Type "q"
Sleep 1s

Hide
Type "pkill -f kafka-console-consumer.sh ; clear"
Enter
Show
