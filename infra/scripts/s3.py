#!/usr/bin/env python3
"""Minimal S3 client for Akamai (Linode) Object Storage — stdlib only, no boto3.

Exists so teardown can EMPTY a bucket before deleting it: the Linode API refuses to
delete a non-empty bucket, and `linode-cli obj` (the usual emptier) needs boto3, which
the platform does not require anywhere else. This signs requests with AWS Signature V4
using urllib + hmac + hashlib, so the only dependency is python3.

    s3.py empty   --endpoint https://us-sea-1.linodeobjects.com --region us-sea \
                  --bucket NAME --access-key AK --secret-key SK
    s3.py put     ... --bucket NAME --key path/obj --data 'hello'   # used by the self-test
    s3.py list    ... --bucket NAME

Path-style addressing (https://<endpoint>/<bucket>/<key>) keeps signing simple. `empty`
lists every object (paginated) and deletes them one by one, then prints the count.
"""

import argparse
import datetime
import hashlib
import hmac
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

_ALGO = "AWS4-HMAC-SHA256"
_SERVICE = "s3"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, datestamp: str, region: str) -> bytes:
    k = _hmac(("AWS4" + secret).encode("utf-8"), datestamp)
    k = _hmac(k, region)
    k = _hmac(k, _SERVICE)
    return _hmac(k, "aws4_request")


def _request(method, endpoint, region, access_key, secret_key,
             bucket, key="", query_params=None, body=b""):
    """Sign + send one S3 request (path-style). Returns (status, headers, body_bytes)."""
    parsed = urllib.parse.urlparse(endpoint)
    host = parsed.netloc
    # Canonical URI: path-style /bucket/key, each char URI-encoded except unreserved + '/'.
    path = bucket + ("/" + key if key else "")
    canonical_uri = "/" + urllib.parse.quote(path, safe="/-_.~")

    # Canonical query string: sorted, URI-encoded keys and values.
    qp = query_params or {}
    canonical_qs = "&".join(
        f"{urllib.parse.quote(str(k), safe='-_.~')}={urllib.parse.quote(str(v), safe='-_.~')}"
        for k, v in sorted(qp.items())
    )

    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = _sha256(body)

    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amzdate}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"

    canonical_request = "\n".join([
        method, canonical_uri, canonical_qs,
        canonical_headers, signed_headers, payload_hash,
    ])
    scope = f"{datestamp}/{region}/{_SERVICE}/aws4_request"
    string_to_sign = "\n".join([_ALGO, amzdate, scope, _sha256(canonical_request.encode("utf-8"))])
    signature = hmac.new(_signing_key(secret_key, datestamp, region),
                         string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    authorization = (
        f"{_ALGO} Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    url = f"{endpoint}{canonical_uri}"
    if canonical_qs:
        url += "?" + canonical_qs
    req = urllib.request.Request(url, data=body if body else None, method=method)
    req.add_header("Host", host)
    req.add_header("x-amz-content-sha256", payload_hash)
    req.add_header("x-amz-date", amzdate)
    req.add_header("Authorization", authorization)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def _ns_strip(tag: str) -> str:
    return tag.split("}", 1)[-1]


def list_keys(args):
    """Yield every object key in the bucket (handles continuation pagination)."""
    keys = []
    token = None
    while True:
        params = {"list-type": "2", "max-keys": "1000"}
        if token:
            params["continuation-token"] = token
        status, _, body = _request("GET", args.endpoint, args.region, args.access_key,
                                   args.secret_key, args.bucket, query_params=params)
        if status != 200:
            sys.stderr.write(f"ERROR: list returned HTTP {status}\n{body.decode('utf-8', 'replace')[:500]}\n")
            sys.exit(1)
        root = ET.fromstring(body)
        token = None
        for el in root:
            t = _ns_strip(el.tag)
            if t == "Contents":
                for child in el:
                    if _ns_strip(child.tag) == "Key":
                        keys.append(child.text)
            elif t == "NextContinuationToken":
                token = el.text
        if not token:
            break
    return keys


def cmd_list(args):
    for k in list_keys(args):
        print(k)


def cmd_put(args):
    """Upload one object (used only by the self-test to create something to delete)."""
    status, _, body = _request("PUT", args.endpoint, args.region, args.access_key,
                               args.secret_key, args.bucket, key=args.key,
                               body=args.data.encode("utf-8"))
    if status not in (200, 201):
        sys.stderr.write(f"ERROR: put returned HTTP {status}\n{body.decode('utf-8','replace')[:500]}\n")
        sys.exit(1)
    print(f"put {args.key} ({len(args.data)} bytes)")


def cmd_empty(args):
    keys = list_keys(args)
    deleted = 0
    for k in keys:
        status, _, body = _request("DELETE", args.endpoint, args.region, args.access_key,
                                   args.secret_key, args.bucket, key=k)
        if status in (200, 204):
            deleted += 1
        else:
            sys.stderr.write(f"WARN: delete '{k}' returned HTTP {status}\n")
    print(f"emptied {args.bucket}: deleted {deleted}/{len(keys)} object(s)")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("list", "empty", "put"):
        p = sub.add_parser(name)
        p.add_argument("--endpoint", required=True, help="https://<cluster>.linodeobjects.com")
        p.add_argument("--region", required=True, help="SigV4 region (the OS region id, e.g. us-sea)")
        p.add_argument("--bucket", required=True)
        p.add_argument("--access-key", required=True)
        p.add_argument("--secret-key", required=True)
        if name == "put":
            p.add_argument("--key", required=True)
            p.add_argument("--data", default="")
    args = ap.parse_args()
    {"list": cmd_list, "empty": cmd_empty, "put": cmd_put}[args.cmd](args)


if __name__ == "__main__":
    main()
