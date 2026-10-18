#!/data/data/com.termux/files/usr/bin/bash
set -u

REPO="KozeiroKodak/pmobiletest"
PROJECT="$HOME/PMOBILE-Android"
RESULT="$HOME/pmobile-bridge/codex-result.txt"
COMMENT_FILE="$HOME/pmobile-bridge/comment.txt"

echo "===== PMOBILE BRIDGE v3 ====="

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

BRANCH="$(git -C "$PROJECT" branch --show-current)" || exit 1
STATUS="$(git -C "$PROJECT" status --short)" || exit 1

echo
echo "===== DADOS COLETADOS ====="
echo "Branch: $BRANCH"
echo "Status:"
printf '%s\n' "$STATUS"
echo "===== FIM ====="

echo
echo "===== TESTE CODEX ====="

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
} | proot \
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

echo
echo "===== PUBLICACAO NO GITHUB ====="

if [ "$CODEX_EXIT" -ne 0 ] || [ ! -s "$RESULT" ]; then
  echo "Falha no Codex. Marcando tarefa como failed."

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
  echo "Executado pelo receiver v3 em modo de análise, sem alterações no projeto."
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
  echo "Falha ao publicar resultado."

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
echo "===== PMOBILE BRIDGE v3 FINALIZADO ====="
