# REST API
resource "aws_api_gateway_rest_api" "loglineos" {
  name        = "${var.project}-api-${var.environment}"
  description = "LogLineOS Ledger API"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# API Gateway Stage
resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.loglineos.id
  stage_name    = var.environment
  
  throttle_settings {
    burst_limit = var.api_throttle_burst_limit
    rate_limit  = var.api_throttle_rate_limit
  }
}

# API Deployment
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.loglineos.id
  
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.spans.id,
      aws_api_gateway_method.spans_post.id,
    ]))
  }
  
  lifecycle {
    create_before_destroy = true
  }
  
  depends_on = [
    aws_api_gateway_method.spans_post,
    aws_api_gateway_integration.spans_post,
  ]
}

# Resources
resource "aws_api_gateway_resource" "spans" {
  rest_api_id = aws_api_gateway_rest_api.loglineos.id
  parent_id   = aws_api_gateway_rest_api.loglineos.root_resource_id
  path_part   = "spans"
}

resource "aws_api_gateway_resource" "boot" {
  rest_api_id = aws_api_gateway_rest_api.loglineos.id
  parent_id   = aws_api_gateway_rest_api.loglineos.root_resource_id
  path_part   = "boot"
}

# Methods - POST /spans
resource "aws_api_gateway_method" "spans_post" {
  rest_api_id   = aws_api_gateway_rest_api.loglineos.id
  resource_id   = aws_api_gateway_resource.spans.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "spans_post" {
  rest_api_id = aws_api_gateway_rest_api.loglineos.id
  resource_id = aws_api_gateway_resource.spans.id
  http_method = aws_api_gateway_method.spans_post.http_method
  
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.api_handler_lambda_arn
}

# Methods - POST /boot
resource "aws_api_gateway_method" "boot_post" {
  rest_api_id   = aws_api_gateway_rest_api.loglineos.id
  resource_id   = aws_api_gateway_resource.boot.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "boot_post" {
  rest_api_id = aws_api_gateway_rest_api.loglineos.id
  resource_id = aws_api_gateway_resource.boot.id
  http_method = aws_api_gateway_method.boot_post.http_method
  
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.stage0_lambda_arn
}

# Lambda permissions
resource "aws_lambda_permission" "api_gateway_stage0" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = element(split(":", var.stage0_lambda_arn), length(split(":", var.stage0_lambda_arn)) - 1)
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.loglineos.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_gateway_handler" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = element(split(":", var.api_handler_lambda_arn), length(split(":", var.api_handler_lambda_arn)) - 1)
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.loglineos.execution_arn}/*/*"
}

# WebSocket API
resource "aws_apigatewayv2_api" "websocket" {
  name                       = "${var.project}-websocket-${var.environment}"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

resource "aws_apigatewayv2_stage" "websocket" {
  api_id      = aws_apigatewayv2_api.websocket.id
  name        = var.environment
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "timeline" {
  api_id           = aws_apigatewayv2_api.websocket.id
  integration_type = "AWS_PROXY"
  integration_uri  = var.timeline_handler_lambda_arn
}

resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.timeline.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.timeline.id}"
}
