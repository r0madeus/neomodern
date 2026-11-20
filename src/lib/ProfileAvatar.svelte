<script lang="ts">
  import { profileInitial, type Profile } from './profiles.svelte'

  let { profile, class: className = 'size-8 text-sm' }: { profile: Profile; class?: string } = $props()
</script>

<span
  class={['flex shrink-0 items-center justify-center rounded-full font-bold text-white select-none', className]}
  style:background={profile.color}
  aria-hidden="true"
>
  {profileInitial(profile.name)}
</span>
