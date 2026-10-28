# Upstream Examples

This directory contains example infrastructure templates that illustrate what upstream backend services look like — one Lambda-based and one ECS/HTTP-based. These correspond directly to the two example services in the `services/` directory (`kongair-bookings` and `kongair-flights`).

> **Purpose:** These are test stubs only. They exist to give you a working end-to-end example of how Kong routes traffic to each upstream type. Do not use these in production.

---

## What's in this template

`kongair-test-upstreams.yaml` is a single CloudFormation stack that deploys both upstream examples together:

| Resource | Type | Corresponds to |
|---|---|---|
| Bookings test Lambda (`kongair-bookings-api-test-<app>-<env>`) | AWS Lambda (Node.js) | `services/kongair-bookings/` — Lambda-backed service |
| Kong invoker IAM role | AWS IAM Role | Used by Kong's AWS Lambda plugin to invoke the function |
| httpbin service | ECS Fargate + ALB | `services/kongair-flights/` — ECS/HTTP-backed service |

### Bookings Lambda

A Node.js stub that implements every endpoint defined in `services/kongair-bookings/openapi.yaml` (`GET/POST /bookings`, `GET/DELETE /bookings/{ticketNumber}`). Kong invokes it directly via the AWS Lambda plugin using IAM role assumption.

The trust chain is:

```
Kong ECS task role (KongEcsTaskRoleArn)
  └─► assumes ──► KongBookingsLambdaInvokerRole
                    └─► invokes ──► kongair-bookings-api-test-<app>-<env>
```

### httpbin (ECS/HTTP) — stand-in for kongair-flights

A Fargate task running `kennethreitz/httpbin` behind an internet-facing ALB. Kong forwards HTTP traffic to it directly — no IAM role needed. It echoes back whatever Kong sends, which is enough to prove the ECS/ALB routing pattern end to end without standing up the real flights service.

---

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `Environment` | Yes | — | `dev`, `qa`, `uat`, or `prd` |
| `AppName` | No | `kongair` | Prefix used in all resource names |
| `KongEcsTaskRoleArn` | Yes | — | ARN of the Kong ECS task role — trusted by the Lambda invoker role |

The Kong ECS task role ARN is an output of the Kong data plane CloudFormation stack. Ask the platform team if you don't have it.

---

## Deploy

### Prerequisites

- AWS CLI configured with credentials that have permissions to create IAM roles, Lambda functions, ECS clusters, ALBs, and VPC resources
- The Kong data plane already deployed (you need its ECS task role ARN)

### Deploy the stack

```bash
aws cloudformation deploy \
  --template-file upstream-examples/kongair-test-upstreams.yaml \
  --stack-name kongair-test-upstreams-dev \
  --parameter-overrides \
      Environment=dev \
      AppName=kongair \
      KongEcsTaskRoleArn=arn:aws:iam::123456789012:role/kong-kongair-task-role-dev \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-2
```

Replace `KongEcsTaskRoleArn` with the actual ARN from your Kong data plane stack.

### Get the outputs

```bash
aws cloudformation describe-stacks \
  --stack-name kongair-test-upstreams-dev \
  --query "Stacks[0].Outputs" \
  --output table \
  --region ap-southeast-2
```

Key outputs you'll need for Bitbucket deployment variables:

| Output key | Use as |
|---|---|
| `LambdaFunctionArn` | `KONGAIR_BOOKINGS_LAMBDA_ARN` |
| `KongInvokerRoleArn` | `KONGAIR_BOOKINGS_IAM_ROLE_ARN` |
| `FlightsServiceUrl` | `KONGAIR_FLIGHTS_UPSTREAM_URL` |

### Wire up the services

After deploying, set these Bitbucket deployment variables for the corresponding `releases/<env>` branch (see the root [`README.md`](../README.md) for the full variable reference):

**`kongair-bookings`** (Lambda service)

```
KONGAIR_BOOKINGS_UPSTREAM_TYPE=lambda
KONGAIR_BOOKINGS_LAMBDA_ARN=<LambdaFunctionArn output>
KONGAIR_BOOKINGS_IAM_ROLE_ARN=<KongInvokerRoleArn output>
```

**`kongair-flights`** (ECS service)

```
KONGAIR_FLIGHTS_UPSTREAM_URL=<FlightsServiceUrl output>
```

`KONGAIR_FLIGHTS_UPSTREAM_TYPE` can be left unset — `ecs` is the default.

Push to `releases/dev` (or whichever environment) and the APIOps pipeline will pick up the new values on the next run.

---

## Tear down

```bash
aws cloudformation delete-stack \
  --stack-name kongair-test-upstreams-dev \
  --region ap-southeast-2
```

Note: CloudFormation will attempt to delete all resources including the VPC and IAM roles. If deletion fails on the IAM roles (due to session policies still attached), wait a few minutes and retry.

---

## Resources created

```
IAM
  kongair-bookings-test-lambda-execution-role-<env>   Lambda execution role (CloudWatch Logs)
  kong-bookings-lambda-invoker-role-<app>-<env>        Assumed by Kong to invoke Lambda

Lambda
  kongair-bookings-api-test-<app>-<env>                Bookings API stub (Node.js 22)

VPC (for the flights ECS stand-in)
  kongair-flights-vpc-<app>-<env>                      10.0.0.0/16
  kongair-flights-igw-<app>-<env>                      Internet gateway
  kongair-flights-public-subnet-1/2                    10.0.1.0/24, 10.0.2.0/24 (two AZs)

ECS + ALB (httpbin stand-in for flights)
  kongair-flights-test-<app>-<env>                     ECS cluster
  kongair-flights-test-<app>-<env>                     Fargate service (kennethreitz/httpbin)
  kongair-flights-alb-<app>-<env>                      Internet-facing ALB (HTTP:80)
  kongair-flights-ecs-exec-role-<app>-<env>            ECS task execution role

CloudWatch
  /ecs/kongair-flights-test-<app>-<env>                Log group (7-day retention)
```
