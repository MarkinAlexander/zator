<script setup lang="ts">
import { computed } from 'vue'
import type { RouteLocationRaw } from 'vue-router'
import { confirmDialog } from '../../stores/confirm'

const props = defineProps<{
  label: string
  value: string
  stateClass?: string
  subText?: string
  to?: RouteLocationRaw
  cli?: string
  compact?: boolean
  cornerAction?: () => void
  cornerBusy?: boolean
  cornerTitle?: string
}>()

const isLong = computed(() => props.value.length > 18)
const hasSub = computed(() => Boolean(props.subText))

function cliHint() {
  confirmDialog({
    title: `«${props.label}» настраивается в CLI`,
    message: `Эта настройка недоступна в Web-панели. Запустите меню z2r на роутере и выберите пункт ${props.cli?.replace('п.', '')}.`,
    confirmText: 'Понятно',
    info: true,
  })
}
</script>

<template>
  <router-link v-if="to" :to="to" class="stat-card is-link" :class="{ 'is-compact': compact }">
    <span class="label">{{ label }}<span class="card-go" aria-hidden="true">→</span></span>
    <strong :class="['value', stateClass, { 'is-long': isLong }]">{{ value }}</strong>
    <span class="value-sub" :hidden="!hasSub">{{ subText || '' }}</span>
  </router-link>
  <article v-else class="stat-card" :class="{ 'is-cli': cli, 'is-compact': compact }" :role="cli ? 'button' : undefined"
    :tabindex="cli ? 0 : undefined" @click="cli && cliHint()" @keydown.enter.prevent="cli && cliHint()">
    <span class="label">{{ label }}<span v-if="cli" class="cli-hint">CLI: {{ cli }}</span></span>
    <strong :class="['value', stateClass, { 'is-long': isLong }]">{{ value }}</strong>
    <span class="value-sub" :hidden="!hasSub">{{ subText || '' }}</span>
    <button v-if="cornerAction" type="button" id="update-check-btn" class="card-corner-action"
      :title="cornerTitle || ''" :disabled="cornerBusy" :aria-busy="cornerBusy"
      @click.stop="cornerAction()" @keydown.stop>
      <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
        <path d="M13.2 8A5.2 5.2 0 1 1 11.7 4.3" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
        <path d="M12.1 1.3v3.3H8.8" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
  </article>
</template>
