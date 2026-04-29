# NV2DATA API 레퍼런스

## `NV2DATA.GetStore(config, template)`
새로운 데이터 저장소를 초기화합니다.
- `config`: `DataStoreName` 등을 포함하는 설정 테이블.

## `Store:LoadProfileAsync(key, force)`
세션 잠금(Session Locking)을 적용하여 플레이어 프로필을 안전하게 로드합니다.

## `Profile:Reconcile()`
기본 템플릿 값을 기존 데이터에 병합합니다. (스키마 업데이트 시 필수)
