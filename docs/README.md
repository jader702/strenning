# Camera Streaming

## Arquitetura

Internet -> Nginx 80/443 -> `/var/www/cameras` e painel `/admin/`.

O canal existente e gerado por `cameras-site-hls-centro-sls.service`, usando FFmpeg para ler RTSP e publicar HLS em `/var/www/cameras/hls`.

## URLs

- Site: `https://cameras.radiowebcriativa.com.br/`
- Painel: `https://cameras.radiowebcriativa.com.br/admin/`
- HLS atual: `https://cameras.radiowebcriativa.com.br/hls/centro-sls.m3u8`

## Status

```bash
systemctl status nginx cameras-site-hls-centro-sls.service camera-streaming-status.timer
nginx -t
certbot certificates
curl -I https://cameras.radiowebcriativa.com.br/hls/centro-sls.m3u8
```

## Como adicionar uma camera

1. Criar um arquivo separado e restrito para a URL RTSP, fora do Git, com permissao `600`.
2. Testar o codec sem publicar credenciais em logs.
3. Se o video for H.264, preferir FFmpeg com `-c:v copy` para remuxar sem transcodificar.
4. Se for H.265, avaliar antes de ativar transcodificacao para H.264.
5. Criar uma unidade systemd separada para o canal.
6. Adicionar o canal em `/opt/camera-streaming/config/channels.env`.
7. Rodar `/opt/camera-streaming/bin/generate-status.sh`.

## Backup

Arquivos principais:

- `/opt/camera-streaming`
- `/etc/nginx/sites-available/cameras.radiowebcriativa.com.br`
- `/etc/nginx/nginx.conf`
- `/etc/systemd/system/camera-streaming-status.service`
- `/etc/systemd/system/camera-streaming-status.timer`
- `/etc/letsencrypt`

Backups desta manutencao foram criados em `/root/camera-streaming-backups/`.

## Rollback

1. Restaurar o vhost Nginx a partir do backup datado.
2. Validar com `nginx -t`.
3. Aplicar somente `systemctl reload nginx`.
4. Desativar o timer do painel, se necessario:

```bash
systemctl disable --now camera-streaming-status.timer
rm -f /etc/systemd/system/camera-streaming-status.service
rm -f /etc/systemd/system/camera-streaming-status.timer
systemctl daemon-reload
```

