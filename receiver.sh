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
# APPLY
# ============================================================

if [ "$MODE" = "APPLY" ]; then
  echo
  echo "===== APPLY CONTROLADO NO WORKTREE ====="

  apply_fail() {
    echo "FALHA APPLY: $1"
    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:pending" \
      --remove-label "pmobile:processing" \
      --add-label "pmobile:failed" >/dev/null 2>&1 || true
    exit 1
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

  INITIAL_STATUS="$(git -C "$WORKTREE" status --porcelain)" || apply_fail "nao foi possivel verificar worktree"
  if [ -n "$INITIAL_STATUS" ]; then
    echo "$INITIAL_STATUS"
    apply_fail "worktree precisa estar limpo antes do APPLY"
  fi

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

  FINAL_STATUS="$(git -C "$WORKTREE" status --porcelain)" || apply_fail "nao foi possivel validar resultado do Codex"
  CHANGED_FILES="$(git -C "$WORKTREE" status --porcelain | sed 's/^...//')" || apply_fail "nao foi possivel listar arquivos alterados"
  VALID=1
  [ "$CODEX_EXIT" -eq 0 ] || VALID=0
  [ -n "$FINAL_STATUS" ] || VALID=0

  while IFS= read -r CHANGED_FILE; do
    [ -n "$CHANGED_FILE" ] || continue
    if ! printf '%s\n' "$ALLOWED_FILES" | grep -Fqx -- "$CHANGED_FILE"; then
      echo "FALHA: arquivo fora da allowlist: $CHANGED_FILE"
      VALID=0
    fi
  done <<EOF_APPLY_CHANGED
$CHANGED_FILES
EOF_APPLY_CHANGED
  [ "$VALID" -eq 1 ] || apply_fail "validacao independente reprovada; nenhum commit criado"

  # Stage cada caminho permitido que foi alterado; nunca usar staging amplo.
  while IFS= read -r ALLOWED_FILE; do
    [ -n "$ALLOWED_FILE" ] || continue
    if printf '%s\n' "$CHANGED_FILES" | grep -Fqx -- "$ALLOWED_FILE"; then
      git -C "$WORKTREE" add -A -- "$ALLOWED_FILE" || apply_fail "falha ao adicionar caminho permitido ao staging"
    fi
  done <<EOF_APPLY_STAGE
$ALLOWED_FILES
EOF_APPLY_STAGE

  STAGED_FILES="$(git -C "$WORKTREE" diff --cached --name-only)" || apply_fail "nao foi possivel validar staging"
  [ -n "$STAGED_FILES" ] || apply_fail "nenhuma alteracao staged; commit vazio impedido"
  while IFS= read -r STAGED_FILE; do
    [ -n "$STAGED_FILE" ] || continue
    if ! printf '%s\n' "$ALLOWED_FILES" | grep -Fqx -- "$STAGED_FILE"; then
      apply_fail "caminho staged fora da allowlist: $STAGED_FILE"
    fi
  done <<EOF_APPLY_STAGED
$STAGED_FILES
EOF_APPLY_STAGED

  git -C "$WORKTREE" diff --cached --check || apply_fail "git diff --cached --check falhou"
  ISSUE_COMMIT="bridge: apply issue #$NUMBER"
  git -C "$WORKTREE" commit -m "$ISSUE_COMMIT" || apply_fail "commit falhou"
  COMMIT_HASH="$(git -C "$WORKTREE" rev-parse HEAD)" || apply_fail "nao foi possivel ler commit criado"

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
    echo "Nenhum push foi realizado."
  } > "$COMMENT_FILE"

  if ! gh issue comment "$NUMBER" --repo "$REPO" --body-file "$COMMENT_FILE"; then
    apply_fail "commit criado, mas falhou ao comentar resultado"
  fi
  gh issue edit "$NUMBER" --repo "$REPO" --remove-label "pmobile:processing" --add-label "pmobile:done" >/dev/null || apply_fail "commit criado, mas falhou ao marcar issue done"
  echo "APPLY concluido: $COMMIT_HASH; sem push."
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

  INITIAL_STATUS="$(
    git -C "$WORKTREE" status --porcelain
  )"

  if [ -n "$INITIAL_STATUS" ]; then
    echo "ERRO: worktree nao esta limpo."
    printf '%s\n' "$INITIAL_STATUS"

    gh issue edit "$NUMBER" \
      --repo "$REPO" \
      --remove-label "pmobile:pending" \
      --add-label "pmobile:failed" >/dev/null

    exit 1
  fi

  echo "Worktree validado:"
  echo "$WORKTREE"
  echo "Estado inicial: LIMPO"

  gh issue edit "$NUMBER" \
    --repo "$REPO" \
    --remove-label "pmobile:pending" \
    --add-label "pmobile:processing" >/dev/null || exit 1

  rm -f "$RESULT"

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
