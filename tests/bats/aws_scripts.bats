#!/usr/bin/env bats
# AWS スクリプト群の引数バリデーション（aws CLI は PATH モック）

load test_helper

setup() {
    setup_mock_bin
    # aws CLI モック: コマンドに応じて応答
    make_mock_script aws '
case "$1 $2" in
  "configure list") echo "OK"; exit 0 ;;
  "sts get-caller-identity") echo "{\"Account\":\"000000000000\",\"UserId\":\"AID\",\"Arn\":\"arn:aws:iam::000000000000:user/test\"}"; exit 0 ;;
  "ec2 describe-instances")
      echo "{\"Reservations\":[{\"Instances\":[{\"InstanceId\":\"i-0test\",\"State\":{\"Name\":\"running\"}}]}]}"; exit 0 ;;
  "ec2 describe-volumes")
      echo "{\"Volumes\":[{\"VolumeId\":\"vol-0test\",\"State\":\"in-use\"}]}"; exit 0 ;;
  "ec2 create-image")
      echo "{\"ImageId\":\"ami-0test\"}"; exit 0 ;;
  "ec2 describe-images")
      echo "{\"Images\":[]}"; exit 0 ;;
  "ec2 create-snapshot")
      echo "{\"SnapshotId\":\"snap-0test\"}"; exit 0 ;;
  "ec2 describe-snapshots")
      echo "{\"Snapshots\":[]}"; exit 0 ;;
  "s3 ls") echo ""; exit 0 ;;
  "s3 cp") exit 0 ;;
  *) exit 0 ;;
esac
'
}
teardown() { teardown_mock_bin; }

# ─── backup_ami.sh ───────────────────────────────────────────────

@test "backup_ami: -i も -p も無いと exit 1" {
    run bash "${SCRIPTS_DIR}/aws/backup_ami.sh"
    [ "$status" -eq 1 ]
}

@test "backup_ami: -i が無いと exit 1" {
    run bash "${SCRIPTS_DIR}/aws/backup_ami.sh" -p prod
    [ "$status" -eq 1 ]
}

@test "backup_ami: -p が無いと exit 1" {
    run bash "${SCRIPTS_DIR}/aws/backup_ami.sh" -i i-0abcd1234
    [ "$status" -eq 1 ]
}

@test "backup_ami: aws CLI 不在は exit 10" {
    teardown_mock_bin
    setup_mock_bin
    PATH="$MOCK_BIN_DIR:/usr/bin:/bin"
    if command -v aws >/dev/null 2>&1; then
        skip "aws CLI present in system PATH"
    fi
    run bash "${SCRIPTS_DIR}/aws/backup_ami.sh" -i i-0abcd1234 -p prod
    [ "$status" -eq 10 ]
}

# ─── backup_ebs_snapshot.sh ──────────────────────────────────────

@test "backup_ebs_snapshot: -v も -p も無いと exit 1" {
    run bash "${SCRIPTS_DIR}/aws/backup_ebs_snapshot.sh"
    [ "$status" -eq 1 ]
}

@test "backup_ebs_snapshot: -v が無いと exit 1" {
    run bash "${SCRIPTS_DIR}/aws/backup_ebs_snapshot.sh" -p prod
    [ "$status" -eq 1 ]
}

# ─── ec2ctl.sh ───────────────────────────────────────────────────

@test "ec2ctl: 引数なしは exit 1" {
    run bash "${SCRIPTS_DIR}/aws/ec2ctl.sh"
    [ "$status" -eq 1 ]
}

@test "ec2ctl: 不正アクションは exit 1" {
    run bash "${SCRIPTS_DIR}/aws/ec2ctl.sh" foo -i i-0test
    [ "$status" -eq 1 ]
}

# ─── s3upload.sh ─────────────────────────────────────────────────

@test "s3upload: ファイルもバケットも無いと exit 1" {
    run bash "${SCRIPTS_DIR}/aws/s3upload.sh"
    [ "$status" -eq 1 ]
}
