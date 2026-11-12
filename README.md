# Tech Briefing Agent

A serverless agent that emails a daily AI news briefing. Once a day, EventBridge Scheduler wakes a Lambda function, which pulls the last day's AI headlines from public RSS feeds, asks Claude to turn them into a short briefing, and sends it by email through SNS. Then everything goes idle until tomorrow.

```
EventBridge Scheduler (7:00 AM ET)
        │
        ▼
Lambda (Python 3.13) ──► RSS feeds (TechCrunch, The Verge, Ars Technica, VentureBeat, MIT Tech Review)
        │
        ├──► SSM Parameter Store (Claude API key, SecureString)
        ├──► Claude API (Haiku) ── writes the briefing
        ▼
SNS topic ──► Email
```

## Design choices

- **Cheap by design.** One Lambda run per day, no servers, no NAT gateway. News comes from free RSS feeds, so Claude only reads headlines and short snippets (capped at 40 articles), and the reply is capped by `max_tokens`. Uses Haiku, the lowest-cost Claude model.
- **No dependencies.** The Lambda calls the Claude Messages API with Python's standard library, so there is no layer or packaging step. Terraform zips the single file.
- **API key stays out of Terraform state.** The key lives in an SSM SecureString that you create once from the CLI. Terraform only builds its ARN for the IAM policy and never reads the value.
- **Least privilege.** The Lambda role can write to its own log group, read that one parameter, and publish to that one topic. The Scheduler role can invoke only this function, with an `aws:SourceAccount` condition.
- **Resilient.** A failing feed is logged and skipped; the briefing still goes out from the others.

## Deploy

1. Store your Claude API key (once):
   ```bash
   aws ssm put-parameter \
     --name /tech-briefing/anthropic-api-key \
     --type SecureString \
     --value "sk-ant-..."
   ```
2. Set your email:
   ```bash
   cp terraform.tfvars.example terraform.tfvars   # then edit the email line
   ```
3. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```
4. **Confirm the SNS subscription** from the email AWS sends you. Nothing arrives until you do.

## Test it now (don't wait for 7 AM)

```bash
aws lambda invoke --function-name tech-briefing-tf-lambda out.json && cat out.json
```

`{"status": "sent", ...}` means the email is on its way. Logs (including Claude token usage per run) are in CloudWatch under `/aws/lambda/tech-briefing-tf-lambda`.

## Customize

All in `terraform.tfvars`:

| Variable | Default | Notes |
|---|---|---|
| `schedule_expression` | `cron(0 7 * * ? *)` | `cron(0 7 ? * MON-FRI *)` for weekdays only |
| `schedule_timezone` | `America/New_York` | |
| `claude_model` | `claude-haiku-5-5` | |
| `max_tokens` | `1200` | Caps reply length and cost |
| `feeds` | 5 AI feeds | Any RSS or Atom URLs |

## Tear down

```bash
terraform destroy
aws ssm delete-parameter --name /tech-briefing/anthropic-api-key
```
