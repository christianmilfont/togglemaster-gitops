#!/usr/bin/env bash
# Rollback de versao POR GIT: volta image.tag para a versao anterior no GitOps.
#
# Por que Git e nao `kubectl rollout undo`: o ArgoCD tem selfHeal=true e reaplicaria
# a tag ruim. O estado desejado vive no Git, entao o rollback tambem.
#
# Idempotente: o Grafana pode mandar o alerta mais de uma vez. A tag anterior e gravada
# de forma EXPLICITA (nao e `git revert`, que se desfaria no segundo disparo) e, se o
# ultimo commit do values ja for um rollback, o script nao faz nada.
#
# Entrada (variaveis de ambiente):
#   SVC           servico em alerta (auth-service)
#   ALERT         nome do alerta, so para a mensagem do commit
#   DRY_RUN       "true" mostra a decisao e nao commita nem faz push
#   MAX_AGE_MIN   so reverte se a versao atual foi publicada ha menos que isso (padrao 120)
# Saida: linhas key=value em $GITHUB_OUTPUT (result, from_tag, to_tag) e no stdout.
# Rodar na raiz do repo GitOps, com o historico completo (fetch-depth: 0).
set -euo pipefail

SVC="${SVC:?defina SVC}"
ALERT="${ALERT:-manual}"
DRY_RUN="${DRY_RUN:-false}"
MAX_AGE_MIN="${MAX_AGE_MIN:-120}"

# servico -> pasta de values (mesmo mapeamento do cd-container: gitops_path)
case "$SVC" in
  auth-service) VALUES="apps/auth/values.yaml" ;;
  *) echo "Servico '$SVC' sem mapeamento de rollback" >&2; exit 1 ;;
esac
TAGPATH='.["base-microservice"].image.tag'

out() { # result, from, to
  echo "result=$1"; echo "from_tag=${2:-}"; echo "to_tag=${3:-}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "result=$1"; echo "from_tag=${2:-}"; echo "to_tag=${3:-}"; } >> "$GITHUB_OUTPUT"
  fi
}

current="$(yq eval "$TAGPATH" "$VALUES")"
IFS=$'\t' read -r last_hash last_epoch last_subject < <(git log -1 --format='%H%x09%ct%x09%s' -- "$VALUES")
echo "Servico: $SVC | tag atual: $current | ultimo commit: ${last_hash:0:7} ($last_subject)"

# 1) Idempotencia: o ultimo commit ja e um rollback -> nada a fazer.
case "$last_subject" in
  "rollback(gitops):"*)
    echo "Ultimo commit do values ja e um rollback. Nada a fazer."
    out already_rolled_back "$current" "$current"; exit 0 ;;
esac

# 2) Guarda de idade: versao antiga demais nao e culpada por um alerta agora.
age_min=$(( ( $(date +%s) - last_epoch ) / 60 ))
if [ "$age_min" -gt "$MAX_AGE_MIN" ]; then
  echo "A versao atual foi publicada ha ${age_min} min (limite ${MAX_AGE_MIN}). Nao parece deploy ruim; sem rollback."
  out too_old "$current" ""; exit 0
fi

# 3) Tag anterior: a versao mais recente no historico do arquivo que seja diferente da atual.
previous=""
while read -r c; do
  t="$(git show "$c:$VALUES" | yq eval "$TAGPATH" - 2>/dev/null || true)"
  if [ -n "$t" ] && [ "$t" != "null" ] && [ "$t" != "$current" ]; then previous="$t"; break; fi
done < <(git log --format=%H -- "$VALUES")

if [ -z "$previous" ]; then
  echo "Sem versao anterior no historico de $VALUES." >&2
  out no_previous "$current" ""; exit 1
fi
echo "Rollback: $current -> $previous"

if [ "$DRY_RUN" = "true" ]; then
  echo "[dry-run] nada foi alterado."
  out dry_run "$current" "$previous"; exit 0
fi

# 4) Grava a tag anterior de forma explicita, commita e faz push (com retry por rebase).
export PREV="$previous"
yq eval -i "$TAGPATH = env(PREV)" "$VALUES"
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$VALUES"
git commit -q -m "rollback(gitops): $SVC $current -> $previous (alerta: $ALERT)"

for attempt in 1 2 3 4 5; do
  if git push origin HEAD:main; then
    out rolled_back "$current" "$previous"; exit 0
  fi
  echo "Push rejeitado (tentativa $attempt de 5); rebase e nova tentativa."
  git pull --rebase origin main
  # Se outro rollback entrou nesse intervalo, o nosso virou vazio/duplicado: nao insistir.
  if [ "$(yq eval "$TAGPATH" "$VALUES")" != "$previous" ]; then
    echo "O values mudou durante o rebase; reavalie o alerta." >&2
    out conflict "$current" "$previous"; exit 1
  fi
  sleep 2
done
echo "Falha ao enviar o rollback apos 5 tentativas." >&2
out push_failed "$current" "$previous"; exit 1
