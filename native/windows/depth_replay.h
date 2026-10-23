#pragma once
namespace winbridge {
enum class ReplayResult { CAPTURED, STENCIL_UNSUPPORTED, ALLOCATION_FAILED };
// Api is the GLES state boundary. Allocation may disturb texture bindings;
// restore them before the native shader samples them. Supplemental depth has
// no copy of the original stencil buffer, so stencil draws fail closed.
template<class Api,class Draw>
ReplayResult capture_depth(Api& api,bool first,Draw&& draw){
  if(api.stencil_enabled())return ReplayResult::STENCIL_UNSUPPORTED;
  const bool scissor=api.scissor_enabled();
  if(!api.allocate())return ReplayResult::ALLOCATION_FAILED;
  api.restore_samplers();
  api.bind_depth_target();
  api.configure_depth();
  if(first){api.scissor(false);api.clear_depth();}
  api.scissor(scissor);
  draw();
  return ReplayResult::CAPTURED;
}
}
