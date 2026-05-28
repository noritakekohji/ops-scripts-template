#!/usr/bin/env python3
"""
_assemble_json.py  -  aws_instance_audit の内部ヘルパー

AWS CLI が一時ディレクトリ ($TMPD) に出力した生 JSON 群と、環境変数で渡された
IMDS メタデータを 1 つの監査 JSON に束ねて $OUT に書き出す。
Linux 版 aws_instance_audit.sh / Windows 版 Get-AwsInstanceAudit.ps1 の両方から
呼ばれる（出力フォーマットを 1 箇所に集約するため）。

必要な環境変数:
  TMPD, OUT, CATS, HOSTNAME_S, REGION, INST_ID, INST_TYPE, AMI, AZ,
  LOCAL_IP, PUBLIC_IP, VPC_ID, SUBNET_ID, IAM_ROLE
"""
import json, os, datetime

tmp = os.environ['TMPD']


def load(name):
    p = os.path.join(tmp, name)
    if not os.path.exists(p):
        return None
    try:
        with open(p, encoding='utf-8-sig') as f:
            return json.load(f)
    except Exception:
        return None


def want(cat):
    cats = os.environ.get('CATS', 'all')
    return cats == 'all' or cat in [c.strip() for c in cats.split(',')]


def env(name):
    return os.environ.get(name, '')


now_jst = (datetime.datetime.utcnow() + datetime.timedelta(hours=9)).strftime('%Y-%m-%d %H:%M:%S')

result = {
    'meta': {
        'tool': 'aws_instance_audit',
        'collected_at': now_jst,
        'hostname': env('HOSTNAME_S'),
        'region': env('REGION'),
        'instance_id': env('INST_ID'),
        'categories': env('CATS') or 'all',
    }
}

# ---- instance metadata + tags ----
if want('instance'):
    tags = {}
    td = load('tags.json')
    if td and isinstance(td.get('Tags'), list):
        for t in td['Tags']:
            tags[t.get('Key', '')] = t.get('Value', '')
    result['instance'] = {
        'instance_id':       env('INST_ID'),
        'instance_type':     env('INST_TYPE'),
        'ami_id':            env('AMI'),
        'availability_zone': env('AZ'),
        'region':            env('REGION'),
        'private_ip':        env('LOCAL_IP'),
        'public_ip':         env('PUBLIC_IP'),
        'vpc_id':            env('VPC_ID'),
        'subnet_id':         env('SUBNET_ID'),
        'tags':              tags,
    }

# ---- IAM ----
if want('iam'):
    role_name = env('IAM_ROLE')
    iam = {'role_name': role_name, 'attached_policies': [], 'inline_policies': [],
           'role_arn': ''}
    rj = load('iam_role.json')
    if rj and isinstance(rj.get('Role'), dict):
        iam['role_arn'] = rj['Role'].get('Arn', '')
        iam['create_date'] = rj['Role'].get('CreateDate', '')
    aj = load('iam_attached.json')
    if aj and isinstance(aj.get('AttachedPolicies'), list):
        iam['attached_policies'] = [
            {'name': p.get('PolicyName', ''), 'arn': p.get('PolicyArn', '')}
            for p in aj['AttachedPolicies']
        ]
    ij = load('iam_inline.json')
    if ij and isinstance(ij.get('PolicyNames'), list):
        iam['inline_policies'] = list(ij['PolicyNames'])
    result['iam'] = iam

# ---- Security Groups ----
if want('sg'):
    def norm_perm(perms):
        out = []
        for p in perms or []:
            proto = p.get('IpProtocol', '')
            proto = 'all' if proto == '-1' else proto
            ranges = [r.get('CidrIp', '') for r in p.get('IpRanges', [])]
            ranges += [r.get('CidrIpv6', '') for r in p.get('Ipv6Ranges', [])]
            sgrefs = [g.get('GroupId', '') for g in p.get('UserIdGroupPairs', [])]
            out.append({
                'protocol':  proto,
                'from_port': p.get('FromPort'),
                'to_port':   p.get('ToPort'),
                'cidrs':     [c for c in ranges if c],
                'sg_refs':   [s for s in sgrefs if s],
            })
        return out

    sgs = []
    sj = load('sg.json')
    if sj and isinstance(sj.get('SecurityGroups'), list):
        for g in sj['SecurityGroups']:
            sgs.append({
                'group_id':    g.get('GroupId', ''),
                'group_name':  g.get('GroupName', ''),
                'description': g.get('Description', ''),
                'vpc_id':      g.get('VpcId', ''),
                'ingress':     norm_perm(g.get('IpPermissions')),
                'egress':      norm_perm(g.get('IpPermissionsEgress')),
            })
    result['security_groups'] = sgs

# ---- Network ----
if want('network'):
    net = {}
    vj = load('vpc.json')
    if vj and isinstance(vj.get('Vpcs'), list) and vj['Vpcs']:
        v = vj['Vpcs'][0]
        net['vpc'] = {'vpc_id': v.get('VpcId', ''), 'cidr': v.get('CidrBlock', ''),
                      'is_default': v.get('IsDefault', False)}
    sj = load('subnet.json')
    if sj and isinstance(sj.get('Subnets'), list) and sj['Subnets']:
        s = sj['Subnets'][0]
        net['subnet'] = {'subnet_id': s.get('SubnetId', ''), 'cidr': s.get('CidrBlock', ''),
                         'az': s.get('AvailabilityZone', ''),
                         'map_public_ip': s.get('MapPublicIpOnLaunch', False)}
    ej = load('eni.json')
    if ej and isinstance(ej.get('NetworkInterfaces'), list):
        net['enis'] = [
            {'eni_id': e.get('NetworkInterfaceId', ''),
             'private_ip': e.get('PrivateIpAddress', ''),
             'subnet_id': e.get('SubnetId', ''),
             'description': e.get('Description', ''),
             'groups': [g.get('GroupId', '') for g in e.get('Groups', [])]}
            for e in ej['NetworkInterfaces']
        ]
    rj = load('rt.json')
    if rj and isinstance(rj.get('RouteTables'), list):
        rts = []
        for r in rj['RouteTables']:
            routes = [{'dest': rt.get('DestinationCidrBlock', rt.get('DestinationPrefixListId', '')),
                       'target': rt.get('GatewayId', rt.get('NatGatewayId',
                                  rt.get('NetworkInterfaceId', rt.get('TransitGatewayId', ''))))}
                      for rt in r.get('Routes', [])]
            rts.append({'route_table_id': r.get('RouteTableId', ''), 'routes': routes})
        net['route_tables'] = rts
    result['network'] = net

out_path = os.environ['OUT']
out_dir = os.path.dirname(out_path)
if out_dir and not os.path.isdir(out_dir):
    os.makedirs(out_dir, exist_ok=True)
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(result, f, ensure_ascii=False, indent=2, default=str)
print(out_path)
