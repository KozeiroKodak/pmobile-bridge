#!/data/data/com.termux/files/usr/bin/bash
set -u

REPO="KozeiroKodak/pmobiletest"
PROJECT="$HOME/PMOBILE-Android"
WORKTREE="$HOME/PMOBILE-BRIDGE-WORK"
RESULT="$HOME/pmobile-bridge/codex-result.txt"
COMMENT_FILE="$HOME/pmobile-bridge/comment.txt"

echo "===== PMOBILE BRIDGE v5 ====="

TASK="$(
  gh issue list \
    --repo "$REPO" \
    --state open \
    --label "pmobile:pending" \
    --search '"[PMOBILE-BRIDGE]" in:title' \
    --limit 1 \
    --json number,title \
    --jq '.[0] | select(. != null) | "\(.number)|\(.title)"'
)"

if [ -z "$TASK" ]; then
  echo "Nenhuma tarefa pendente."
  exit 0
fi

IFS='|' read -r NUMBER TITLE <<< "$TASK"

echo "Tarefa: #$NUMBER - $TITLE"

BODY="$(
  gh issue view "$NUMBER" \
    --repo "$REPO" \
    --json body \
    --jq '.body'
)" || exit 1

MODE="$(
  printf '%s\n' "$BODY" |
  sed -n 's/^MODO:[[:space:]]*//p' |
  head -n 1 |
  tr '[:lower:]' '[:upper:]'
)"

TARGET="$(
  printf '%s\n' "$BODY" |
  sed -n 's/^ALVO:[[:space:]]*//p' |
  head -n 1 |
  tr '[:lower:]' '[:upper:]'
)"

[ -z "$TARGET" ] && TARGET="PMOBILE"

case "$TARGET" in
  PMOBILE)
    PROJECT="$HOME/PMOBILE-Android"
    WORKTREE="$HOME/PMOBILE-BRIDGE-WORK"
    ;;
  BRIDGE)
    PROJECT="$HOME/pmobile-bridge"
    WORKTREE="$HOME/pmobile-bridge-work"
    ;;
  *)
    echo "ERRO: ALVO invalido: $TARGET"
    exit 1
    ;;
esac

echo "Modo detectado: ${MODE:-NAO INFORMADO}"
echo "Alvo detectado: $TARGET"

# ============================================================
# AUDIT — leitura direta do projeto real, sem uso de WORKTREE
# ============================================================

if [ "$MODE" = "AUDIT" ]; then
  if [ "$TARGET" != "PMOBILE" ]; then
    echo "ERRO: AUDIT permitido somente para ALVO: PMOBILE."
    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:pending" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null 2>&1 || true
    exit 1
  fi

  audit_fail() {
    local reason="$1"
    echo "AUDIT falhou: $reason"
    {
      echo "## Resultado automático do PMOBILE Bridge"
      echo
      echo "### AUDIT somente-leitura"
      echo
      echo "Resultado: FALHA"
      echo
      echo "Diagnóstico: $reason"
    } > "$COMMENT_FILE"
    gh issue comment "$NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE" >/dev/null 2>&1 || true
    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:pending" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null 2>&1 || true
    exit 1
  }

  [ -d "$PROJECT" ] || audit_fail "projeto real nao encontrado: $PROJECT"
  PROJECT_ABS="$(cd "$PROJECT" 2>/dev/null && pwd -P)" || audit_fail "nao foi possivel resolver caminho do projeto"
  AUDIT_BRANCH="$(git -C "$PROJECT_ABS" branch --show-current 2>/dev/null)" || audit_fail "nao foi possivel ler branch do projeto"
  AUDIT_HEAD="$(git -C "$PROJECT_ABS" rev-parse HEAD 2>/dev/null)" || audit_fail "nao foi possivel ler HEAD do projeto"
  AUDIT_STATUS="$(git -C "$PROJECT_ABS" status --short 2>/dev/null)" || audit_fail "nao foi possivel ler status do projeto"

  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:pending" \
    --add-label "pmobile:processing" >/dev/null || audit_fail "nao foi possivel marcar issue como processing"

  rm -f "$RESULT"
  {
    echo "Voce esta executando uma auditoria tecnica somente-leitura do projeto PMOBILE real."
    echo
    echo "PROJECT absoluto: $PROJECT_ABS"
    echo "Branch atual: ${AUDIT_BRANCH:-DETACHED HEAD}"
    echo "HEAD atual: $AUDIT_HEAD"
    echo "Status atual (git status --short):"
    printf '%s\n' "$AUDIT_STATUS"
    echo
    echo "As alteracoes locais existentes sao preservadas e fazem parte do snapshot auditado."
    echo "Inspecione o projeto diretamente neste diretorio e execute comandos de diagnostico somente-leitura que sejam necessarios."
    echo "Nao altere nada no projeto: nao escreva arquivos, nem faca git add/stage, commit, push, checkout, reset, clean, stash, merge ou cherry-pick."
    echo "Nao crie, edite, stageie ou publique arquivos no repositorio PMOBILE, nem faca qualquer outra alteracao nele."
    echo
    echo "===== INSTRUCAO DA ISSUE ====="
    printf '%s\n' "$BODY"
    echo "===== FIM DA INSTRUCAO ====="
  } |
  proot \
    -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
    -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
    codex --no-daemon exec \
      --sandbox read-only \
      --cd "$PROJECT_ABS" \
      --output-last-message "$RESULT" \
      -
  CODEX_EXIT=$?

  if [ "$CODEX_EXIT" -ne 0 ] || [ ! -s "$RESULT" ]; then
    audit_fail "Codex falhou ou nao gerou resultado final"
  fi

  {
    echo "## Resultado automático do PMOBILE Bridge"
    echo
    echo "### AUDIT somente-leitura"
    echo
    echo "Projeto: $PROJECT_ABS"
    echo "Branch: ${AUDIT_BRANCH:-DETACHED HEAD}"
    echo "HEAD: $AUDIT_HEAD"
    echo "Status inicial registrado; alteracoes locais existentes fazem parte do snapshot auditado."
    echo
    cat "$RESULT"
  } > "$COMMENT_FILE"

  if ! gh issue comment "$NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE"; then
    audit_fail "falhou ao publicar resultado da auditoria"
  fi
  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:processing" \
    --add-label "pmobile:done" >/dev/null || audit_fail "falhou ao marcar issue done"

  echo "AUDIT concluido; resultado salvo em $RESULT."
  exit 0
fi

# ============================================================
# APPLY
# ============================================================

if [ "$MODE" = "APPLY" ]; then
  echo
  echo "===== APPLY CONTROLADO NO WORKTREE ====="

  apply_fail() {
    local reason="$1"
    local current_head=""
    local local_commit=""
    current_head="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
    if [ "${APPLY_FAILURE_STAGE:-}" = "publication" ] && [ -n "${COMMIT_HASH:-}" ]; then
      local_commit="$COMMIT_HASH"
      echo "FALHA DE PUBLICACAO/DESTINO: $reason"
      echo "Commit local preservado: $local_commit"
    elif [ -n "${WORKTREE_HEAD:-}" ] && [ -n "$current_head" ] && [ "$current_head" != "$WORKTREE_HEAD" ]; then
      local_commit="$current_head"
      echo "FALHA APPLY APOS COMMIT: $reason"
      echo "Commit local criado pelo APPLY: $local_commit"
    elif [ -n "${COMMIT_HASH:-}" ]; then
      local_commit="$COMMIT_HASH"
      if [ "${APPLY_FAILURE_STAGE:-}" = "publication" ]; then
        echo "FALHA DE PUBLICACAO/DESTINO: $reason"
      else
        echo "FALHA APPLY APOS COMMIT: $reason"
      fi
      echo "Commit local preservado: $local_commit"
    else
      echo "FALHA APPLY ANTES DO COMMIT: $reason"
      echo "Nenhum commit do APPLY identificado localmente."
    fi
    {
      echo "## Resultado automático do PMOBILE Bridge"
      echo
      echo "### APPLY controlado"
      echo
      echo "Resultado: FALHA"
      echo
      if [ -n "$local_commit" ]; then
        echo "Commit local criado/preservado: $local_commit"
      else
        echo "Falha antes da criação de commit; nenhum commit do APPLY identificado localmente."
      fi
      echo
      echo "Diagnóstico: $reason"
      echo
      if [ "${APPLY_FAILURE_STAGE:-}" = "publication" ]; then
        echo "Falha na etapa publication; o commit local permanece preservado."
      else
        echo "Publicação: não executada pelo receiver."
      fi
      echo
      echo "Validações executadas: allowlist e validação independente do receiver até o ponto da falha."
    } > "$COMMENT_FILE"
    gh issue comment "$NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE" >/dev/null 2>&1 || true
    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:pending" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null 2>&1 || true
    exit 1
  }

  apply_report_fail() {
    echo "FALHA DE REPORTE/FINALIZACAO NO GITHUB: $1"
    echo "O commit local $COMMIT_HASH foi criado na branch isolada $WORKTREE_BRANCH."
    if [ "${PUSH_CONFIRMED:-0}" -eq 1 ]; then
      echo "O push de $COMMIT_HASH para $PUSH_BRANCH foi confirmado pelo SHA remoto; somente o reporte/finalizacao no GitHub falhou."
    else
      echo "O APPLY local foi concluido; somente o reporte/finalizacao no GitHub falhou. Nenhum push foi confirmado."
    fi
    exit 1
  }

  load_status_paths() {
    local status_file="$1"
    local record path status
    CHANGED_PATHS=()
    git -C "$WORKTREE" status --porcelain=v1 -z --untracked-files=all > "$status_file" || return 1
    while IFS= read -r -d '' record; do
      [ -n "$record" ] || continue
      status="${record:0:2}"
      path="${record:3}"
      CHANGED_PATHS+=("$path")
      case "$status" in
        *R*|*C*)
          IFS= read -r -d '' path || return 1
          CHANGED_PATHS+=("$path")
          ;;
      esac
    done < "$status_file"
  }

  if [ ! -d "$WORKTREE/.git" ] && [ ! -f "$WORKTREE/.git" ]; then
    apply_fail "worktree nao encontrado: $WORKTREE"
  fi

  REAL_HEAD="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null)" || apply_fail "nao foi possivel ler HEAD do projeto real"
  WORKTREE_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null)" || apply_fail "nao foi possivel ler HEAD do worktree"
  WORKTREE_BRANCH="$(git -C "$WORKTREE" branch --show-current 2>/dev/null)" || apply_fail "nao foi possivel ler branch do worktree"

  if [ "$TARGET" = "BRIDGE" ]; then
    if ! git -C "$WORKTREE" merge-base --is-ancestor "$REAL_HEAD" "$WORKTREE_HEAD"; then
      apply_fail "worktree do BRIDGE esta atras ou divergente do projeto real"
    fi
  elif [ "$REAL_HEAD" != "$WORKTREE_HEAD" ]; then
    apply_fail "projeto real e worktree possuem HEADs diferentes"
  fi

  if [ -z "$WORKTREE_BRANCH" ]; then
    apply_fail "worktree esta em detached HEAD; commit exige branch"
  fi

  STATUS_FILE="$(mktemp)" || apply_fail "nao foi possivel criar arquivo temporario de validacao"
  if ! git -C "$WORKTREE" status --porcelain=v1 -z --untracked-files=all > "$STATUS_FILE"; then
    rm -f "$STATUS_FILE"
    apply_fail "nao foi possivel verificar worktree"
  fi
  if [ -s "$STATUS_FILE" ]; then
    git -C "$WORKTREE" status --short
    rm -f "$STATUS_FILE"
    apply_fail "worktree precisa estar limpo antes do APPLY"
  fi
  rm -f "$STATUS_FILE"

  ALLOWED_FILES="$(
    printf '%s\n' "$BODY" |
    sed -n '/^ARQUIVOS_PERMITIDOS:[[:space:]]*$/,/^FIM_ARQUIVOS_PERMITIDOS[[:space:]]*$/p' |
    sed '1d;$d;/^[[:space:]]*$/d'
  )"
  [ -n "$ALLOWED_FILES" ] || apply_fail "APPLY sem ARQUIVOS_PERMITIDOS"

  INVALID_ALLOWLIST=0
  while IFS= read -r ALLOWED_FILE; do
    case "$ALLOWED_FILE" in
      /*|..|../*|*/..|*/../*|.git|.git/*|*/.git|*/.git/*)
        echo "Caminho proibido: $ALLOWED_FILE"
        INVALID_ALLOWLIST=1
        ;;
    esac
  done <<EOF_APPLY_ALLOWED
$ALLOWED_FILES
EOF_APPLY_ALLOWED
  [ "$INVALID_ALLOWLIST" -eq 0 ] || apply_fail "allowlist invalida"

  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:pending" \
    --add-label "pmobile:processing" >/dev/null || apply_fail "nao foi possivel marcar issue como processing"

  rm -f "$RESULT"
  {
    echo "Voce esta executando APPLY controlado do PMOBILE Bridge."
    echo
    echo "DIRETORIO DE TRABALHO:"
    echo "$WORKTREE"
    echo
    echo "REGRAS OBRIGATORIAS:"
    echo "- Trabalhe SOMENTE no diretorio atual."
    echo "- Edite SOMENTE os arquivos listados em ARQUIVOS_PERMITIDOS."
    echo "- NAO faca commit nem push; o receiver fara o commit validado."
    echo "- NAO use checkout, reset, clean, stash, merge ou cherry-pick."
    echo "- Nao altere arquivos fora da tarefa."
    echo
    echo "===== INSTRUCAO DA ISSUE ====="
    printf '%s\n' "$BODY"
    echo "===== FIM DA INSTRUCAO ====="
  } |
  proot \
    -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
    -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
    codex --no-daemon exec \
      --dangerously-bypass-approvals-and-sandbox \
      --cd "$WORKTREE" \
      --output-last-message "$RESULT" \
      -
  CODEX_EXIT=$?

  STATUS_FILE="$(mktemp)" || apply_fail "nao foi possivel criar arquivo temporario de validacao"
  load_status_paths "$STATUS_FILE" || { rm -f "$STATUS_FILE"; apply_fail "nao foi possivel validar resultado do Codex"; }
  rm -f "$STATUS_FILE"
  VALID=1
  [ "$CODEX_EXIT" -eq 0 ] || VALID=0
  [ "${#CHANGED_PATHS[@]}" -gt 0 ] || VALID=0

  ALLOWED_PATHS=()
  while IFS= read -r ALLOWED_FILE; do
    [ -n "$ALLOWED_FILE" ] && ALLOWED_PATHS+=("$ALLOWED_FILE")
  done <<EOF_APPLY_ALLOWED_ARRAY
$ALLOWED_FILES
EOF_APPLY_ALLOWED_ARRAY

  for CHANGED_FILE in "${CHANGED_PATHS[@]}"; do
    FOUND_ALLOWED=0
    for ALLOWED_FILE in "${ALLOWED_PATHS[@]}"; do
      [ "$CHANGED_FILE" = "$ALLOWED_FILE" ] && FOUND_ALLOWED=1 && break
    done
    if [ "$FOUND_ALLOWED" -ne 1 ]; then
      printf 'FALHA: arquivo fora da allowlist: %q\n' "$CHANGED_FILE"
      VALID=0
    fi
  done
  [ "$VALID" -eq 1 ] || apply_fail "validacao independente reprovada"

  # Stage cada caminho permitido que foi alterado; nunca usar staging amplo.
  for ALLOWED_FILE in "${ALLOWED_PATHS[@]}"; do
    for CHANGED_FILE in "${CHANGED_PATHS[@]}"; do
      if [ "$CHANGED_FILE" = "$ALLOWED_FILE" ]; then
        git -C "$WORKTREE" add -A -- "$ALLOWED_FILE" || apply_fail "falha ao adicionar caminho permitido ao staging"
        break
      fi
    done
  done

  STAGED_FILE="$(mktemp)" || apply_fail "nao foi possivel criar arquivo temporario de validacao staged"
  git -C "$WORKTREE" diff --cached --name-only --no-renames -z > "$STAGED_FILE" || { rm -f "$STAGED_FILE"; apply_fail "nao foi possivel validar staging"; }
  STAGED_PATHS=()
  while IFS= read -r -d '' STAGED_PATH; do
    STAGED_PATHS+=("$STAGED_PATH")
  done < "$STAGED_FILE"
  rm -f "$STAGED_FILE"
  [ "${#STAGED_PATHS[@]}" -gt 0 ] || apply_fail "nenhuma alteracao staged; commit vazio impedido"
  for STAGED_PATH in "${STAGED_PATHS[@]}"; do
    FOUND_ALLOWED=0
    for ALLOWED_FILE in "${ALLOWED_PATHS[@]}"; do
      [ "$STAGED_PATH" = "$ALLOWED_FILE" ] && FOUND_ALLOWED=1 && break
    done
    [ "$FOUND_ALLOWED" -eq 1 ] || { printf 'caminho staged fora da allowlist: %q\n' "$STAGED_PATH"; apply_fail "caminho staged fora da allowlist"; }
  done

  git -C "$WORKTREE" diff --cached --check || apply_fail "git diff --cached --check falhou"
  ISSUE_COMMIT="bridge: apply issue #$NUMBER"
  git -C "$WORKTREE" commit -m "$ISSUE_COMMIT" || apply_fail "commit falhou"
  COMMIT_HASH="$(git -C "$WORKTREE" rev-parse HEAD)" || apply_fail "nao foi possivel ler commit criado"
  PUSH_CONFIRMED=0
  PUSH_DIRECTIVES="$(printf '%s\n' "$BODY" | sed -n '/^PUSH:/p' | wc -l | tr -d '[:space:]')"
  PUSH_YES_COUNT="$(printf '%s\n' "$BODY" | sed -n '/^PUSH:[[:space:]]*YES[[:space:]]*$/p' | wc -l | tr -d '[:space:]')"
  PUSH_ENABLED=0
  if [ "$PUSH_DIRECTIVES" -gt 0 ]; then
    [ "$PUSH_DIRECTIVES" -eq 1 ] && [ "$PUSH_YES_COUNT" -eq 1 ] || apply_fail "diretiva PUSH ambigua; commit local $COMMIT_HASH permanece criado"
    PUSH_ENABLED=1
  fi

  if [ "$PUSH_ENABLED" -eq 1 ]; then
    APPLY_FAILURE_STAGE=publication
    if [ "$TARGET" != "BRIDGE" ]; then
      apply_fail "publicacao solicitada para alvo sem destino permitido; push desabilitado e commit local $COMMIT_HASH preservado"
    fi
    case "$NUMBER" in
      ''|*[!0-9]*) apply_fail "numero da issue invalido para determinar destino de publicacao; push desabilitado e commit local $COMMIT_HASH preservado" ;;
    esac
    [ "$NUMBER" -gt 0 ] 2>/dev/null || apply_fail "numero da issue invalido para determinar destino de publicacao; push desabilitado e commit local $COMMIT_HASH preservado"
    EXPECTED_REMOTE="$(git -C "$WORKTREE" remote get-url origin 2>/dev/null || true)"
    if [ -z "$EXPECTED_REMOTE" ]; then
      apply_fail "destino de publicacao indisponivel: remoto origin nao configurado; push desabilitado e commit local $COMMIT_HASH preservado"
    fi
    PUSH_BRANCH="pmobile-issue-$NUMBER-apply"
    case "$PUSH_BRANCH" in
      main|android-capacitor|ota-update|master|develop|release|production)
        apply_fail "branch protegida rejeitada: $PUSH_BRANCH; commit local $COMMIT_HASH preservado" ;;
    esac
    case "$PUSH_BRANCH" in
      pmobile-issue-[0-9]*-apply) ;;
      *) apply_fail "branch de publicacao invalida: $PUSH_BRANCH; commit local $COMMIT_HASH preservado" ;;
    esac

    REMOTE_REF="refs/heads/$PUSH_BRANCH"
    REMOTE_BEFORE="$(git -C "$WORKTREE" ls-remote --heads origin "$REMOTE_REF" 2>/dev/null)" || \
      apply_fail "nao foi possivel consultar origin antes do push; commit local $COMMIT_HASH preservado"
    if [ -n "$REMOTE_BEFORE" ]; then
      REMOTE_BEFORE_SHA="${REMOTE_BEFORE%%[[:space:]]*}"
      if [ "$REMOTE_BEFORE_SHA" != "$COMMIT_HASH" ]; then
        apply_fail "branch remota $PUSH_BRANCH ja existe com SHA incompativel ($REMOTE_BEFORE_SHA); commit local $COMMIT_HASH preservado"
      fi
    fi

    if ! git -C "$WORKTREE" push origin "HEAD:$REMOTE_REF"; then
      apply_fail "git push para origin/$PUSH_BRANCH falhou; commit local $COMMIT_HASH preservado"
    fi

    REMOTE_AFTER="$(git -C "$WORKTREE" ls-remote --heads origin "$REMOTE_REF" 2>/dev/null)" || \
      apply_fail "nao foi possivel confirmar SHA remoto apos push para $PUSH_BRANCH; commit local $COMMIT_HASH preservado"
    REMOTE_AFTER_SHA="${REMOTE_AFTER%%[[:space:]]*}"
    if [ -z "$REMOTE_AFTER_SHA" ] || [ "$REMOTE_AFTER_SHA" != "$COMMIT_HASH" ]; then
      apply_fail "SHA remoto de $PUSH_BRANCH nao corresponde ao commit APPLY ($COMMIT_HASH; remoto: ${REMOTE_AFTER_SHA:-ausente}); commit local preservado"
    fi
    PUSH_CONFIRMED=1
    echo "Publicacao confirmada: origin/$PUSH_BRANCH -> $REMOTE_AFTER_SHA"
  fi
  printf -v STAGED_FILES '%s\n' "${STAGED_PATHS[@]}"

  {
    echo "## Resultado automático do PMOBILE Bridge"
    echo
    echo "### APPLY controlado"
    echo
    echo "Resultado: APROVADO"
    echo
    echo "Commit: $COMMIT_HASH ($ISSUE_COMMIT)"
    echo
    echo "Arquivos commitados:"
    printf '```text\n%s\n```\n' "$STAGED_FILES"
    echo
    echo "Commit criado somente na branch isolada: $WORKTREE_BRANCH"
    if [ "$PUSH_CONFIRMED" -eq 1 ]; then
      echo "Push confirmado: refs/heads/$PUSH_BRANCH aponta para $COMMIT_HASH."
    else
      echo "Publicacao/push nao solicitada."
    fi
  } > "$COMMENT_FILE"

  if ! gh issue comment "$NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE"; then
    apply_report_fail "falhou ao comentar resultado"
  fi
  gh issue edit "$NUMBER" --repo "$REPO" --remove-label "pmobile:processing" --add-label "pmobile:done" >/dev/null || apply_report_fail "falhou ao marcar issue done"
  if [ "$PUSH_CONFIRMED" -eq 1 ]; then
    echo "APPLY concluido: $COMMIT_HASH; push confirmado em $PUSH_BRANCH."
  else
    echo "APPLY concluido: $COMMIT_HASH; sem push."
  fi
  exit 0
fi

BRANCH="$(git -C "$PROJECT" branch --show-current)" || exit 1
STATUS="$(git -C "$PROJECT" status --short)" || exit 1

echo
echo "===== PROJETO REAL ====="
echo "Branch: $BRANCH"
echo "Status:"
printf '%s\n' "$STATUS"
echo "===== FIM ====="

# ============================================================
# ANALYZE
# ============================================================

if [ "$MODE" = "ANALYZE" ] || [ -z "$MODE" ]; then

  echo
  echo "===== CODEX / ANALYZE ====="

  rm -f "$RESULT"

  {
    echo "Você está participando de um teste controlado do PMOBILE Bridge."
    echo
    echo "REGRAS OBRIGATORIAS:"
    echo "- NAO execute comandos."
    echo "- NAO use shell ou outras ferramentas."
    echo "- NAO leia arquivos."
    echo "- NAO altere arquivos."
    echo "- Analise SOMENTE os dados fornecidos neste prompt."
    echo
    echo "===== INSTRUCAO DA ISSUE ====="
    printf '%s\n' "$BODY"
    echo "===== FIM DA INSTRUCAO ====="
    echo
    echo "===== DADOS COLETADOS PELO RECEPTOR ====="
    printf 'BRANCH: %s\n' "$BRANCH"
    echo "GIT STATUS --SHORT:"
    printf '%s\n' "$STATUS"
    echo "===== FIM DOS DADOS ====="
  } |
  proot \
    -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
    -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
    codex --no-daemon exec \
      --sandbox read-only \
      --cd "$PROJECT" \
      --output-last-message "$RESULT" \
      -

  CODEX_EXIT=$?

  echo
  echo "Codex exit code: $CODEX_EXIT"

  if [ -s "$RESULT" ]; then
    echo "===== RESPOSTA FINAL DO CODEX ====="
    cat "$RESULT"
    echo
    echo "===== FIM DA RESPOSTA ====="
  else
    echo "Codex nao gerou resposta final."
  fi

  if [ "$CODEX_EXIT" -ne 0 ] || [ ! -s "$RESULT" ]; then
    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:pending" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null
    exit 1
  fi

  {
    echo "## Resultado automático do PMOBILE Bridge"
    echo
    cat "$RESULT"
    echo
    echo "---"
    echo "Executado pelo receiver v4 em modo de análise, sem alterações no projeto."
  } > "$COMMENT_FILE"

  echo "Estado: pending -> processing"

  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:pending" \
    --add-label "pmobile:processing" >/dev/null || exit 1

  if ! gh issue comment "$NUMBER" \
    --repo "$REPO" \
    --body-file "$COMMENT_FILE"
  then
    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null
    exit 1
  fi

  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:processing" \
    --add-label "pmobile:done" >/dev/null || exit 1

  echo "Estado: processing -> done"
  echo "Tarefa #$NUMBER concluida."
  echo "===== PMOBILE BRIDGE v5 FINALIZADO ====="
  exit 0
fi

# ============================================================
# EDIT
# ============================================================

if [ "$MODE" = "EDIT" ]; then

  echo
  echo "===== CODEX / EDIT CONTROLADO ====="

  # O projeto real pode possuir alteracoes anteriores ao Bridge.
  # Elas sao preservadas e nunca devem ser editadas pelo Codex.
  echo "Alteracoes pre-existentes no projeto real serao preservadas."

  # O worktree precisa existir.
  if [ ! -d "$WORKTREE/.git" ] && [ ! -f "$WORKTREE/.git" ]; then
    echo "ERRO: worktree nao encontrado: $WORKTREE"

    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:pending" \
      --add-label "pmobile:failed" >/dev/null

    exit 1
  fi

  REAL_HEAD="$(
    git -C "$PROJECT" rev-parse HEAD
  )" || exit 1

  WORKTREE_HEAD="$(
    git -C "$WORKTREE" rev-parse HEAD
  )" || exit 1

  echo "HEAD projeto real: $REAL_HEAD"
  echo "HEAD worktree:     $WORKTREE_HEAD"

  if [ "$TARGET" = "BRIDGE" ]; then
    if ! git -C "$WORKTREE" merge-base --is-ancestor "$REAL_HEAD" "$WORKTREE_HEAD"; then
      echo "ERRO: worktree do BRIDGE esta atras ou divergente do projeto real."
      echo "EDIT automatico abortado por seguranca."

      gh issue edit "$NUMBER" \
        --repo "$REPO" \
        --remove-label "pmobile:pending" \
        --add-label "pmobile:failed" >/dev/null

      exit 1
    fi

    echo "HEAD validado: worktree do BRIDGE e igual ou descendente do projeto real."
  else
    if [ "$REAL_HEAD" != "$WORKTREE_HEAD" ]; then
      echo "ERRO: projeto real e worktree possuem HEADs diferentes."
      echo "EDIT automatico abortado por seguranca."

      gh issue edit "$NUMBER" \
        --repo "$REPO" \
        --remove-label "pmobile:pending" \
        --add-label "pmobile:failed" >/dev/null

      exit 1
    fi

    echo "HEAD validado: projeto real e worktree sao iguais."
  fi

  # ALLOWLIST DE ARQUIVOS PARA EDIT
    ALLOWED_FILES="$(
      printf '%s\n' "$BODY" |
      sed -n '/^ARQUIVOS_PERMITIDOS:[[:space:]]*$/,/^FIM_ARQUIVOS_PERMITIDOS[[:space:]]*$/p' |
      sed '1d;$d;/^[[:space:]]*$/d'
    )"

    if [ -z "$ALLOWED_FILES" ]; then
      echo "ERRO: EDIT sem ARQUIVOS_PERMITIDOS."

      gh issue edit "$NUMBER" \
        --repo "$REPO" \
        --remove-label "pmobile:processing" \
        --add-label "pmobile:failed" >/dev/null || true

      exit 1
    fi

    echo "Arquivos permitidos pela tarefa:"
    printf '%s\n' "$ALLOWED_FILES"

    INVALID_ALLOWLIST=0

    while IFS= read -r ALLOWED_FILE; do
      case "$ALLOWED_FILE" in
        /*|..|../*|*/..|*/../*|.git|.git/*|*/.git|*/.git/*)
          echo "ERRO: caminho proibido: $ALLOWED_FILE"
          INVALID_ALLOWLIST=1
          ;;
      esac
    done <<EOF_ALLOWED
$ALLOWED_FILES
EOF_ALLOWED

    if [ "$INVALID_ALLOWLIST" -ne 0 ]; then
      gh issue edit "$NUMBER" \
        --repo "$REPO" \
        --remove-label "pmobile:processing" \
        --add-label "pmobile:failed" >/dev/null || true
      exit 1
    fi

  INITIAL_PATHS_FILE="$(mktemp)" || exit 1
  if ! git -C "$WORKTREE" diff HEAD --name-only --no-renames -z > "$INITIAL_PATHS_FILE" ||
     ! git -C "$WORKTREE" ls-files --others --exclude-standard -z >> "$INITIAL_PATHS_FILE"; then
    rm -f "$INITIAL_PATHS_FILE"
    echo "ERRO: nao foi possivel verificar alteracoes iniciais do worktree."
    exit 1
  fi
  INITIAL_PATHS=()
  while IFS= read -r -d '' INITIAL_PATH; do
    INITIAL_PATHS+=("$INITIAL_PATH")
  done < "$INITIAL_PATHS_FILE"
  rm -f "$INITIAL_PATHS_FILE"

  # Um unico receiver.sh pre-existente e permitido somente se estiver na allowlist.
  if [ "${#INITIAL_PATHS[@]}" -gt 0 ]; then
    if [ "${#INITIAL_PATHS[@]}" -ne 1 ] ||
       [ "${INITIAL_PATHS[0]}" != "receiver.sh" ] ||
       ! printf '%s\n' "$ALLOWED_FILES" | grep -Fqx -- "receiver.sh"; then
      echo "ERRO: worktree possui alteracoes iniciais fora da excecao permitida."
      printf '%s\n' "${INITIAL_PATHS[@]}"

      gh issue edit "$NUMBER" \
        --repo "$REPO" \
        --remove-label "pmobile:pending" \
        --add-label "pmobile:failed" >/dev/null

      exit 1
    fi
    echo "Estado inicial: somente receiver.sh alterado e explicitamente permitido."
  else
    echo "Estado inicial: LIMPO"
  fi

  echo "Worktree validado:"
  echo "$WORKTREE"

  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:pending" \
    --add-label "pmobile:processing" >/dev/null || exit 1

  rm -f "$RESULT"



  {
    echo "Você está executando uma edição CONTROLADA do PMOBILE Bridge."
    echo
    echo "DIRETORIO DE TRABALHO:"
    echo "$WORKTREE"
    echo
    echo "REGRAS OBRIGATORIAS:"
    echo "- Trabalhe SOMENTE no diretorio atual."
    echo "- Execute a tarefa descrita abaixo."
    echo "- NAO faca commit."
    echo "- NAO faca push."
    echo "- NAO use checkout."
    echo "- NAO use reset."
    echo "- NAO use stash."
    echo "- NAO use clean."
    echo "- Nao altere arquivos fora da tarefa."
    echo
    echo "===== INSTRUCAO DA ISSUE ====="
    printf '%s\n' "$BODY"
    echo "===== FIM DA INSTRUCAO ====="
  } |
  proot \
    -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
    -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
    codex --no-daemon exec \
      --dangerously-bypass-approvals-and-sandbox \
      --cd "$WORKTREE" \
      --output-last-message "$RESULT" \
      -

  CODEX_EXIT=$?

  echo
  echo "Codex exit code: $CODEX_EXIT"

  if [ -s "$RESULT" ]; then
    echo "===== RESPOSTA FINAL DO CODEX ====="
    cat "$RESULT"
    echo
    echo "===== FIM DA RESPOSTA ====="
  fi

  # ==========================================================
  # VALIDACAO INDEPENDENTE
  # ==========================================================

  echo
  echo "===== VALIDACAO INDEPENDENTE ====="

  FINAL_STATUS="$(
    git -C "$WORKTREE" status --porcelain
  )"

  echo "Estado final:"
  printf '%s\n' "$FINAL_STATUS"

  VALID=1

  if [ "$CODEX_EXIT" -ne 0 ]; then
    echo "FALHA: Codex retornou erro."
    VALID=0
  fi

  if [ -z "$FINAL_STATUS" ]; then
    echo "FALHA: Codex nao produziu nenhuma alteracao."
    VALID=0
  fi

  CHANGED_FILES="$(
    git -C "$WORKTREE" status --porcelain |
    sed 's/^...//'
  )"

  echo "Arquivos alterados:"
  printf '%s\n' "$CHANGED_FILES"

  while IFS= read -r CHANGED_FILE; do
    [ -z "$CHANGED_FILE" ] && continue

    if ! printf '%s\n' "$ALLOWED_FILES" |
      grep -Fqx -- "$CHANGED_FILE"
    then
      echo "FALHA: arquivo fora da allowlist: $CHANGED_FILE"
      VALID=0
    fi
  done <<EOF_CHANGED
$CHANGED_FILES
EOF_CHANGED

  if [ "$VALID" -ne 1 ]; then
    echo
    echo "RESULTADO: REPROVADO"

    {
      echo "## Resultado automático do PMOBILE Bridge"
      echo
      echo "### EDIT controlado"
      echo
      echo "Resultado: REPROVADO"
      echo
      echo "Estado final do worktree:"
      printf '```text\n%s\n```\n' "$FINAL_STATUS"
      echo
      echo "Resposta do Codex:"
      cat "$RESULT" 2>/dev/null || true
    } > "$COMMENT_FILE"

    gh issue comment "$NUMBER" \
      --repo "$REPO" \
      --body-file "$COMMENT_FILE" >/dev/null || true

    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null || true

    exit 1
  fi

  echo "Arquivos permitidos:"
  printf '%s\n' "$ALLOWED_FILES"
  echo
  echo "Arquivos alterados:"
  printf '%s\n' "$CHANGED_FILES"
  echo
  echo "RESULTADO: APROVADO"

  {
    echo "## Resultado automático do PMOBILE Bridge"
    echo
    echo "### EDIT controlado"
    echo
    echo "Resultado: APROVADO"
    echo
    echo "Arquivos permitidos:"
    printf '```text\n%s\n```\n' "$ALLOWED_FILES"
    echo
    echo "Arquivos alterados:"
    printf '```text\n%s\n```\n' "$CHANGED_FILES"
    echo
    echo "Validacao independente do receiver: OK"
    echo
    echo "Nenhum commit ou push foi realizado."
  } > "$COMMENT_FILE"

  if ! gh issue comment "$NUMBER" \
    --repo "$REPO" \
    --body-file "$COMMENT_FILE"
  then
    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null
    exit 1
  fi

  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:processing" \
    --add-label "pmobile:done" >/dev/null || exit 1

  echo
  echo "Estado: processing -> done"
  echo "Tarefa #$NUMBER concluida."
  echo "===== PMOBILE BRIDGE v5 FINALIZADO ====="
  exit 0
fi

echo "ERRO: modo desconhecido: $MODE"

gh issue edit "$NUMBER" \
  --repo "$REPO" \
  --remove-label "pmobile:pending" \
  --add-label "pmobile:failed" >/dev/null || true

exit 1
