1. Edit your crontab:
   EDITOR=nano crontab -e

2. Add this line to run the script daily at 9 AM:
   0 9 \* \* \* cd <your_path>/wg_company_monitor && /usr/bin/ruby wg_monitor.rb >> wg_monitor.log 2>&1

Cron syntax explained:

- 0 9 \* \* \* = At 9:00 AM every day (minute hour day month weekday)
- cd ... = Change to the script directory first
- > > wg_monitor.log 2>&1 = Append output and errors to log file

3. Save and exit

4. Verify it's scheduled:
   crontab -l

Common times:

- 0 9 \* \* \* - 9:00 AM daily
- 0 12 \* \* \* - Noon daily
- 0 _/6 _ \* \* - Every 6 hours
- 0 9,18 \* \* \* - 9 AM and 6 PM daily

Important for macOS:
You may need to grant Terminal "Full Disk Access" in System Preferences → Security & Privacy → Privacy → Full Disk Access for cron to work properly.
