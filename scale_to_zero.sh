#!/usr/bin/env bash
# =============================================================================
# scale_to_zero.sh — Scale all benchmarking resources to 0
#
# Amaç: GCP (GKE)'deki deneme sonrası gereksiz faturalandırmayı (billing)
# önlemek için tüm pod'ları (vLLM ve Locust) 0'a indirir. 
# Eğer cluster auto-scaler açıksa, pod'lar 0 olunca Nod'lar da bir süre sonra
# kapanacaktır. İsteğe bağlı olarak Node Pool'u manuel 0'a çekebilen yorum 
# satırları da aşağıda mevcuttur.
# =============================================================================

set -e

echo "========================================================"
echo " 🛑 Scale to Zero Script Başlatılıyor..."
echo "========================================================"

echo "1) Locust Deployment'ları 0'a çekiliyor..."
kubectl scale deployment -n locust locust-worker --replicas=0 || true
kubectl scale deployment -n locust locust-master --replicas=0 || true
echo "✅ Locust bileşenleri kapatıldı."

echo "2) vLLM Deployment'ı 0'a çekiliyor..."
kubectl scale deployment -n vllm vllm-server --replicas=0 || true
echo "✅ vLLM sunucusu kapatıldı."

echo ""
echo "⏳ Pod'ların kapanması bekleniyor..."
kubectl wait --for=delete pod -l 'app in (vllm, locust)' --all-namespaces --timeout=120s || true

echo "========================================================"
echo "✅ Tüm hedef pod'lar 0'a indirildi!"
echo "========================================================"
echo ""
echo "ℹ️ NOT: GKE Auto-scaler kullanıyorsan (örneğin gpu-pool üzerinde auto-scaling"
echo "   min=0 ise), pod'lar silindikten yaklasik 10 dakika sonra Node'lar otomatik silinecektir"
echo "   ve GPU faturası duracaktır."
echo ""
echo "Eğer HIZLICA sıfırlamak (Node Pool'u direkt silmek) istersen şu komutu"
echo "terminalden manuel çalıştırabilirsin:"
echo ""
echo "  gcloud container clusters resize vllm-cluster \\"
echo "      --node-pool=gpu-pool \\"
echo "      --num-nodes=0 \\"
echo "      --zone=europe-west3-b \\"
echo "      --quiet"
echo "========================================================"
