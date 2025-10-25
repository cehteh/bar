# Email Module Usage Examples

The email module provides functionality to send emails using the system's `mail` utility.

## Prerequisites

The email module requires one of the following mail utilities to be installed:
- `mail`
- `mailx`
- `sendmail`

Check if a mail utility is available:
```bash
./bar is_mail_installed
```

## Basic Usage

### Example 1: Simple Text Email
```bash
./bar --bare -- '
    require email
    email_send --to recipient@example.com \
        --subject "Test Email" \
        --text "Hello World"
'
```

### Example 2: Email with CC and BCC
```bash
./bar --bare -- '
    require email
    email_send --to user@example.com \
        --cc manager@example.com \
        --bcc archive@example.com \
        --subject "Team Update" \
        --text "This is an update for the team."
'
```

### Example 3: Email from File
```bash
./bar --bare -- '
    require email
    email_send --to user@example.com \
        --subject "Report" \
        --file /path/to/report.txt
'
```

### Example 4: Email with Attachments
```bash
./bar --bare -- '
    require email
    email_send --to user@example.com \
        --subject "Documents" \
        --text "Please find attached documents" \
        --attach /path/to/document.pdf \
        --attach /path/to/spreadsheet.xlsx
'
```

### Example 5: Email from stdin
```bash
echo "Pipeline output" | ./bar --bare -- '
    require email
    email_send --to user@example.com --subject "Output" -
'
```

Or from a command:
```bash
./bar tests 2>&1 | ./bar --bare -- '
    require email
    email_send --to admin@example.com --subject "Test Results" -
'
```

### Example 6: Email with Custom Sender and Reply-To
```bash
./bar --bare -- '
    require email
    email_send --to user@example.com \
        --from notifications@example.com \
        --reply-to support@example.com \
        --subject "Notification" \
        --text "This is an automated notification"
'
```

### Example 7: Multiple Recipients
```bash
./bar --bare -- '
    require email
    email_send --to user1@example.com \
        --to user2@example.com \
        --to user3@example.com \
        --subject "Announcement" \
        --text "Important announcement for all users"
'
```

## Using in Barf Files

You can use the email module in your Barf files for notifications:

```bash
# In your Barf file
require email

# Send notification on test failure
rule notify_on_failure: tests? -- '
    echo "Tests failed!" | email_send \
        --to admin@example.com \
        --subject "Test Failure Alert" \
        -
'

# Send build results
rule send_build_report: build -- '
    email_send \
        --to team@example.com \
        --subject "Build Completed" \
        --text "Build completed successfully" \
        --attach build/report.log
'
```

## Function Reference

### `is_mail_installed`
Check if the 'mail' utility is installed. Returns 0 if available, 1 otherwise.

### `get_mail_command`
Get the available mail command (mail, mailx, or sendmail).

### `email_send`
Send an email using the 'mail' utility.

**Parameters:**
- `--to recipient` - Email recipient (can be specified multiple times, required)
- `--cc recipient` - Carbon copy recipient (can be specified multiple times)
- `--bcc recipient` - Blind carbon copy recipient (can be specified multiple times)
- `--subject subject` - Email subject (required)
- `--from sender` - Sender email address (optional)
- `--reply-to address` - Reply-To email address (optional)
- `--text message` - Email message text (alternative to file or stdin)
- `--file file` - Read message from file (alternative to --text or stdin)
- `-` - Read message from stdin (default if no --text or --file)
- `--attach file` - Attach a file (can be specified multiple times)

## Notes

- If neither `--text`, `--file`, nor `-` is specified, stdin is used by default
- The email module will automatically detect the available mail command
- Multiple `--to`, `--cc`, `--bcc`, and `--attach` options can be specified
- Attachment support requires a mail utility that supports the `-A` flag

For more information, run:
```bash
./bar help email
```
