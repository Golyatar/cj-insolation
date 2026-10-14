"""Read the target model in one command; never runs modeling operations."""
import argparse
import json
import sys
from client import Client


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('--instance')
    parser.add_argument('--selection', action='store_true')
    parser.add_argument('--view', action='store_true')
    parser.add_argument('--reload', action='store_true', help='Developer source reload before capture')
    args = parser.parse_args()
    client = Client(timeout=30)
    def tool(name, arguments):
        result = client.call('tools/call', {'name': name, 'arguments': arguments})['result']
        if result.get('isError'):
            raise RuntimeError(result['content'][0]['text'])
        return result['structuredContent']
    try:
        client.initialize()
        instances = tool('sketchup_list_instances', {})['instances']
        available = [i for i in instances if i.get('available') and (not args.instance or i['instance_id'] == args.instance)]
        if len(available) != 1:
            raise RuntimeError('Select one available instance with --instance: ' + json.dumps(available))
        instance = available[0]['instance_id']
        if args.reload:
            import time
            tool('sketchup_reload_plugin', {'instance_id': instance})
            time.sleep(2)
            available = [i for i in tool('sketchup_list_instances', {})['instances'] if i.get('available') and i['pid'] == available[0]['pid']]
            if len(available) != 1:
                raise RuntimeError('Could not rediscover the reloaded instance')
            instance = available[0]['instance_id']
        status = tool('sketchup_status', {'instance_id': instance})['result']
        target = {'instance_id': instance, 'expected_model_token': status['model_token']}
        snapshot = tool('sketchup_capture_model', dict(target, selection_only=args.selection))['result']
        snapshot.pop('root_entities', None)
        report = {'instance_id': instance, 'snapshot': snapshot}
        if args.view:
            report['view'] = tool('sketchup_capture_view', target)['result']
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        client.close()


if __name__ == '__main__':
    main()
