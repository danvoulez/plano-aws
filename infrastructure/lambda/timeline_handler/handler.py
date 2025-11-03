import json
import boto3

def handler(event, context):
    """Handle WebSocket connections for timeline streaming"""
    
    print(f"Timeline handler invoked: {json.dumps(event)}")
    
    route_key = event.get('requestContext', {}).get('routeKey')
    connection_id = event.get('requestContext', {}).get('connectionId')
    
    try:
        if route_key == '$connect':
            return handle_connect(event, connection_id)
        elif route_key == '$disconnect':
            return handle_disconnect(event, connection_id)
        elif route_key == 'subscribe':
            return handle_subscribe(event, connection_id)
        else:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Unknown route'})
            }
    except Exception as e:
        print(f"Error handling WebSocket event: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def handle_connect(event, connection_id):
    """Handle new WebSocket connection"""
    print(f"New connection: {connection_id}")
    
    # In a full implementation, store connection in DynamoDB
    # For now, just acknowledge the connection
    
    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Connected'})
    }

def handle_disconnect(event, connection_id):
    """Handle WebSocket disconnection"""
    print(f"Disconnection: {connection_id}")
    
    # In a full implementation, remove connection from DynamoDB
    
    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Disconnected'})
    }

def handle_subscribe(event, connection_id):
    """Handle subscribe request"""
    print(f"Subscribe request from {connection_id}")
    
    body = event.get('body', '{}')
    if isinstance(body, str):
        body = json.loads(body)
    
    # In a full implementation, store subscription preferences in DynamoDB
    
    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'Subscribed'})
    }
