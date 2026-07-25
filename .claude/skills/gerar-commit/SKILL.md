---
name: gerar-commit
description: Gera a mensagem de commit no padrão conventional commits a partir do diff em stage. Use ao pedir para commitar ou criar mensagem de commit.
---

# Gerar Commit

Ao gerar um commit:

1. Rode `git diff --staged` e leia as mudanças
2. Classifique o tipo: feat, fix, chore, docs, refactor
3. Monte a mensagem: `tipo: descrição curta no imperativo`
4. Mostre a mensagem e confirme antes de commitar