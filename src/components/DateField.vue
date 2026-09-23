<script setup lang="ts">
/**
 * Date entry that always reads month/day/yyyy. Root is a plain input, so the
 * `class` from the caller styles it like its siblings.
 */
import { computed, ref, watch } from "vue";
import { formatUsDate, maskUsDate, parseUsDate } from "../lib/usDate";

const props = defineProps<{ modelValue?: string | null }>();
const emit = defineEmits<{ "update:modelValue": [value: string] }>();

const text = ref(formatUsDate(props.modelValue));
const focused = ref(false);
// Flag a bad value once the user leaves the field, not while they type it.
const leftField = ref(false);
const invalid = computed(() => leftField.value && text.value.trim() !== "" && !parseUsDate(text.value));

watch(
  () => props.modelValue,
  (value) => {
    if (!focused.value) text.value = formatUsDate(value);
  },
);

function onInput(event: Event) {
  const el = event.target as HTMLInputElement;
  text.value = maskUsDate(el.value);
  if (el.value !== text.value) {
    el.value = text.value;
    el.setSelectionRange(text.value.length, text.value.length);
  }
  const parsed = parseUsDate(text.value);
  if (parsed) emit("update:modelValue", parsed);
}

function onBlur() {
  focused.value = false;
  leftField.value = true;
  const parsed = parseUsDate(text.value);
  // Half-typed text stays put so it can be finished; clearing really clears.
  if (!parsed && !text.value.trim()) emit("update:modelValue", "");
}
</script>

<template>
  <input
    :value="text"
    type="text"
    inputmode="numeric"
    autocomplete="off"
    spellcheck="false"
    placeholder="mm/dd/yyyy"
    :aria-invalid="invalid || undefined"
    :class="{ 'ring-1 ring-red-500/70': invalid }"
    @focus="(focused = true), (leftField = false)"
    @input="onInput"
    @blur="onBlur"
  />
</template>
