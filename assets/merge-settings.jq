# merge-settings.jq — 대상 프로젝트의 settings.json 에 하네스 블록을 병합한다.
#
# 사용:  jq -s -f assets/merge-settings.jq <existing.json> <snippet.json>
#
# 규칙
#   · 객체는 깊게 병합한다 (스칼라 충돌 시 스니펫이 이긴다).
#   · .hooks.<Event> 배열은 이어 붙인 뒤 (matcher, 명령어 목록) 튜플로 중복을
#     제거한다. 그래서 install.sh 재실행이 멱등이고, 무관한 기존 훅은 살아남는다.
#   · .permissions.allow 는 이어 붙인 뒤 unique.
#   · 어느 쪽에도 없던 키는 만들어내지 않는다 (빈 hooks/permissions 를 심지 않는다).

def hook_key: { m: (.matcher // ""), c: [ .hooks[]?.command ] };

def dedupe_entries:
  reduce .[] as $e (
    [];
    if (map(hook_key) | index([$e | hook_key][0])) != null
    then .
    else . + [$e]
    end
  );

.[0] as $a
| .[1] as $b
| ($a * $b)
| ( if (($a.hooks // {}) | length) > 0 or (($b.hooks // {}) | length) > 0
    then .hooks = (
      reduce ( (($a.hooks // {}) | keys_unsorted) + (($b.hooks // {}) | keys_unsorted) | unique )[] as $k
        ({}; .[$k] = ((($a.hooks[$k] // []) + ($b.hooks[$k] // [])) | dedupe_entries))
    )
    else .
    end )
| ( if (($a.permissions // {}) | length) > 0 or (($b.permissions // {}) | length) > 0
    then .permissions = (
      (($a.permissions // {}) * ($b.permissions // {}))
      | if (($a.permissions.allow // []) + ($b.permissions.allow // []) | length) > 0
        then .allow = ((($a.permissions.allow // []) + ($b.permissions.allow // [])) | unique)
        else .
        end
      | if (($a.permissions.deny // []) + ($b.permissions.deny // []) | length) > 0
        then .deny = ((($a.permissions.deny // []) + ($b.permissions.deny // [])) | unique)
        else .
        end
    )
    else .
    end )
