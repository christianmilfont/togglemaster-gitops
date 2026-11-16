# Alertas inteligentes e self-healing

Fluxo:

```
Prometheus (spanmetrics) -> regra Grafana AuthServiceHigh5xxRate (5xx > 5%, 5 min, for 2m)
   -> contact point togglemaster-incident
        |- PagerDuty : abre incidente (Events API v2)
        |- Discord   : mensagem com resumo, runbook e dashboard
        '- webhook   : GitHub repository_dispatch -> .github/workflows/self-heal.yml
                         -> rollback por Git: grava a tag anterior em apps/auth/values.yaml e da push -> ArgoCD aplica
```

Tudo é provisionado por ConfigMaps em `monitoring/dashboards/` (sidecar do Grafana):
`alerting.yaml` (regra, contact points, política) e `togglemaster-incidente.yaml`
(dashboard de incidente, uid `togglemaster-incidente`). Os segredos ficam no secret
`grafana-alerting` (não vai para o Git).

O link do Discord usa o `ExternalURL` do Grafana. Para ele ser clicável, defina
`grafana.ini: server: root_url` com a URL de acesso (hoje o acesso é por port-forward).

## Contra alert fatigue

- Guarda de tráfego: a regra só avalia com mais de 0,05 req/s. Poucos requests não viram 50% de erro.
- `for: 2m`: um pico de segundos não dispara.
- Uma regra, uma política: `group_by [alertname, service]`, `group_wait 30s`, `repeat_interval 4h`.
- 4xx não conta (só spans SERVER com `STATUS_CODE_ERROR`).
- `noDataState: OK`: sem tráfego não acorda ninguém.

## Setup (uma vez)

1. **PagerDuty**: conta gratuita/trial → Services → Add service `togglemaster-auth` →
   Integrations → *Events API v2* → copie a **Integration Key**.
2. **Discord**: servidor → canal `#alertas` → Editar canal → Integrações → Webhooks → copie a URL.
3. **GitHub PAT** (fine-grained) só no repo `togglemaster-gitops`, permissão **Contents: Read and write**
   (necessária para `repository_dispatch`). Pode ser outro token que o `GITOPS_TOKEN`.
4. **Terraform** (cria a role e o acesso ao EKS só no namespace `auth-service`):
   ```bash
   terraform -chdir="$TFENV" apply
   gh variable set SELFHEAL_ROLE_ARN --repo "$GITOPS" --body "$(terraform -chdir="$TFENV" output -raw selfheal_role_arn)"
   ```
5. **Secret do Grafana** (antes/depois do sync; reinicie o Grafana se ele já subiu):
   ```bash
   read -rs PD;  read -rs DC;  read -rs GH_PAT
   kubectl -n monitoring create secret generic grafana-alerting \
     --from-literal=PAGERDUTY_INTEGRATION_KEY="$PD" \
     --from-literal=DISCORD_WEBHOOK_URL="$DC" \
     --from-literal=GITHUB_DISPATCH_TOKEN="$GH_PAT"
   unset PD DC GH_PAT
   kubectl -n monitoring rollout restart deployment/grafana
   ```

## Testes

1. **Self-healing isolado** (sem alerta): Actions → *Self-healing* → Run workflow → `auth-service`.
   Ou: `gh api repos/$GITOPS/dispatches -f event_type=grafana-alert -f 'client_payload[service]=auth-service' -f 'client_payload[status]=firing' -f 'client_payload[alertname]=teste'`
2. **Contact points**: Grafana → Alerting → Contact points → *Test* em cada integração.
3. **Ponta a ponta**: gere 5xx no auth-service (ex.: `kubectl -n auth-service set env deployment/auth-service DATABASE_URL=postgres://x`
   e faça requests contínuos em `/auth/...`). Em ~4 min: incidente no PagerDuty, mensagem no Discord e run da Action.
   Rollback nao resolve defeito de configuracao nem queda de banco: o incidente continua aberto, como esperado. Para demonstrar o rollback, use um deploy com bug (README do self-heal: `scripts/rollback.sh`).
   Reverta pelo ArgoCD (self-heal do Argo restaura o env).

## Notas

- O webhook usa `payload.template` (payload customizado), pois o GitHub exige `event_type`.
  Confirme em Alerting → Contact points → `togglemaster-incident` → Export se o Grafana aceitou o provisionamento.
- O workflow ignora status `resolved` e só reinicia serviços da allowlist (`ALLOWED_SERVICES`).
- Para outro serviço: adicione-o na allowlist, no `allowed_namespaces` do módulo `selfheal` e crie outra regra com `service: <nome>`.

## Agente de triagem (somente leitura)

Antes do rollback, o passo `Diagnostico (agente de triagem)` do `self-heal.yml` roda
`scripts/diagnose.py`: coleta evidencias (pods, imagem, historico de rollout, eventos, logs),
mascara segredos, pede um diagnostico a um LLM (API compativel com OpenAI) e posta no Discord.
Falha do agente nunca bloqueia o rollback; sem LLM, posta um resumo das evidencias.

Configuracao (tudo gratuito): no repo GitOps, `Settings > Secrets and variables > Actions`:

| Tipo | Nome | Exemplo |
|---|---|---|
| variable | `LLM_BASE_URL` | `https://api.groq.com/openai/v1` |
| variable | `LLM_MODEL` | modelo do free tier (confira o catalogo atual do provedor) |
| secret | `LLM_API_KEY` | chave do provedor |
| secret | `DISCORD_WEBHOOK_URL` | a mesma URL do canal `#alertas` |

Repo publico: o script nao escreve evidencias nem a resposta do LLM no log do run.
Teste local sem AWS: `local-alert-test/` (ver README la).
