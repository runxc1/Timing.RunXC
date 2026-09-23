<script setup lang="ts">
/**
 * Date + time entry that always reads month/day/yyyy with a 12-hour clock.
 * `modelValue` is the same local wall-clock string `<input type="datetime-local">`
 * used (`YYYY-MM-DDTHH:mm`), so `toIsoOrNull()` keeps working unchanged.
 */
import { computed, ref, watch } from "vue";
import { formatUsDate, formatUsTime, maskUsDate, parseUsDate, parseUsTime } from "../lib/usDate";

const props = defineProps<{
  modelValue?: string | null;
  /** Classes applied to both inner inputs. */
  inputClass?: string;
}>();
const emit = defineEmits<{ "update:modelValue": [value: string] }>();

function split(value: string | null | undefined): { date: string; time: string } {
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/.exec(value ?? "");
  return m ? { date: m[1], time: m[2] } : { date: "", time: "" };
}

const isoDate = ref(split(props.modelValue).date);
const hhmm = ref(split(props.modelValue).time);
const dateText = ref(formatUsDate(isoDate.value));
const timeText = ref(formatUsTime(hhmm.value));
const focused = ref(false);

// Flag a bad value once the user leaves a field, not while they type it.
const leftDate = ref(false);
const leftTime = ref(false);
const dateInvalid = computed(() => leftDate.value && dateText.value.trim() !== "" && !parseUsDate(dateText.value));
const timeInvalid = computed(() => leftTime.value && timeText.value.trim() !== "" && !parseUsTime(timeText.value));

watch(
  () => props.modelValue,
  (value) => {
    if (focused.value) return;
    const parts = split(value);
    isoDate.value = parts.date;
    hhmm.value = parts.time;
    dateText.value = formatUsDate(parts.date);
    timeText.value = formatUsTime(parts.time);
  },
);

function push() {
  emit("update:modelValue", isoDate.value && hhmm.value ? `${isoDate.value}T${hhmm.value}` : "");
}

function onDateInput(event: Event) {
  const el = event.target as HTMLInputElement;
  dateText.value = maskUsDate(el.value);
  if (el.value !== dateText.value) {
    el.value = dateText.value;
    el.setSelectionRange(dateText.value.length, dateText.value.length);
  }
  const parsed = parseUsDate(dateText.value);
  if (parsed) {
    isoDate.value = parsed;
    push();
  }
}

function onDateBlur() {
  focused.value = false;
  leftDate.value = true;
  const parsed = parseUsDate(dateText.value);
  if (parsed) {
    isoDate.value = parsed;
    push();
  } else if (!dateText.value.trim()) {
    isoDate.value = "";
    push();
  }
}

/** The time field is free-form until blur, so read what is actually on screen. */
function onTimeInput(event: Event) {
  timeText.value = (event.target as HTMLInputElement).value;
}

function onTimeBlur(event: FocusEvent) {
  focused.value = false;
  leftTime.value = true;
  const raw = (event.target as HTMLInputElement | null)?.value ?? timeText.value;
  timeText.value = raw;
  const parsed = parseUsTime(raw);
  if (parsed) {
    hhmm.value = parsed;
    timeText.value = formatUsTime(parsed);
    push();
  } else if (!raw.trim()) {
    hhmm.value = "";
    push();
  }
}
</script>

<template>
  <span class="inline-flex flex-wrap items-center gap-2">
    <input
      :value="dateText"
      type="text"
      inputmode="numeric"
      autocomplete="off"
      spellcheck="false"
      placeholder="mm/dd/yyyy"
      aria-label="Date"
      :aria-invalid="dateInvalid || undefined"
      :class="[inputClass, dateInvalid ? 'ring-1 ring-red-500/70' : '']"
      @focus="(focused = true), (leftDate = false)"
      @input="onDateInput"
      @blur="onDateBlur"
    />
    <input
      :value="timeText"
      type="text"
      inputmode="numeric"
      autocomplete="off"
      spellcheck="false"
      placeholder="hh:mm AM/PM"
      aria-label="Time"
      :aria-invalid="timeInvalid || undefined"
      :class="[inputClass, timeInvalid ? 'ring-1 ring-red-500/70' : '']"
      @focus="(focused = true), (leftTime = false)"
      @input="onTimeInput"
      @blur="onTimeBlur"
    />
  </span>
</template>
